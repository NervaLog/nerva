# IAM Plan: Google OAuth + SMS OTP

## Current State

The codebase has a complete magic link discovery flow:
- `external/stytch/` — SDK wrapper with PKCE, token types, Discovery API
- `integrations/iam-stytch/` — Discovery request lifecycle, distributed locking, flow orchestration
- `modules/iam/` — User, Org, Identity, Membership models with PostgreSQL as source of truth
- `apps/main/endpoints/` — Login, AuthCallback handlers

Key existing support:
- `StytchRedirectToken.TokenType` already includes `discovery_oauth` and `oauth`
- `Discovery.OrgAllowedAuthMethods` already includes `google_oauth`, `microsoft_oauth`
- PKCE infrastructure exists and works

---

## Part 1: Google OAuth (Login with Google)

### Flow Overview

```
┌─────────────┐     GET /login/google
│   Client    │────────────────────────────►┌─────────────────┐
└─────────────┘                             │  Login Endpoint │
                                            └────────┬────────┘
                                                     │ 1. Generate PKCE
                                                     │ 2. Create discovery_request
                                                     │ 3. Build Stytch OAuth URL
                                                     ▼
                                            ┌─────────────────┐
                                            │ 302 → Stytch    │
                                            │ OAuth Discovery │
                                            └────────┬────────┘
                                                     │
                                                     ▼ (Stytch → Google → Stytch)
                                            ┌─────────────────┐
                                            │ GET /auth/callback
                                            │ ?token=...      │
                                            │ &stytch_token_type=discovery_oauth
                                            │ &discovery_request_token=...
                                            └────────┬────────┘
                                                     │ 4. Claim discovery_request
                                                     │ 5. OAuth.discoveryAuthenticate
                                                     │ 6. Create/exchange org
                                                     │ 7. Ensure user in Postgres
                                                     │ 8. Create JWT session
                                                     ▼
                                            ┌─────────────────┐
                                            │ 302 → /         │
                                            │ Set-Cookie: JWT │
                                            └─────────────────┘
```

### Implementation Tasks

#### 1. Add OAuth API wrapper (`external/stytch/`)

**File: `external/stytch/src/main/kotlin/dev/template/stytch/api/OAuth.kt`**

```kotlin
object OAuth {
    /**
     * Authenticate a discovery_oauth token from Google/Microsoft OAuth.
     * Similar to MagicLinks.discoveryAuthenticate but for OAuth tokens.
     */
    context(client: StytchB2BClient, _: Raise<StytchError>)
    fun discoveryAuthenticate(
        token: StytchRedirectToken,
        codeVerifier: Pkce.CodeVerifier
    ): DiscoveryAuthenticateResponse
}
```

Uses `client.oauth.discovery.authenticate()` from Stytch SDK.

#### 2. Add OAuth discovery request flow (`integrations/iam-stytch/`)

**File: `integrations/iam-stytch/.../discovery/flows/RequestOAuthDiscovery.kt`**

```kotlin
object RequestOAuthDiscovery {
    context(_: PostgRestClient, _: Raise<IamStytchError>)
    operator fun invoke(
        provider: OAuthProvider,  // GOOGLE, MICROSOFT
        redirectTo: Uri,
        stytchPublicToken: String
    ): OAuthDiscoveryRedirect  // Contains URL to redirect user to
}
```

This will:
1. Generate PKCE verifier/challenge
2. Create `discovery_request` in DB (stores verifier, no email yet — OAuth provides it)
3. Build Stytch OAuth discovery start URL with:
   - `public_token`
   - `pkce_code_challenge`
   - `discovery_redirect_url` (includes our opaque token)

#### 3. Update AuthenticateCallback to handle OAuth tokens

**File: `integrations/iam-stytch/.../discovery/actions/AuthenticateCallback.kt`**

Modify to dispatch based on token type:
```kotlin
when (token.type) {
    TokenType.discovery -> MagicLinks.discoveryAuthenticate(...)
    TokenType.discovery_oauth -> OAuth.discoveryAuthenticate(...)
    else -> raise(UnsupportedTokenType)
}
```

#### 4. Add Login endpoint for OAuth initiation

**File: `apps/main/.../endpoints/Login.kt`**

Add route:
```kotlin
"/google" bind GET to { request ->
    // 1. Call RequestOAuthDiscovery(GOOGLE, redirectTo)
    // 2. Return 302 to Stytch OAuth URL
}
```

#### 5. Update discovery_requests table (if needed)

Current schema stores `email` as NOT NULL. For OAuth, email comes from the provider callback.
Options:
- Make `email` nullable (OAuth fills it during callback)
- Add `provider` column to track auth method

**Migration: `V{epoch}__iam_stytch__oauth-support.sql`**

```sql
ALTER TABLE iam_stytch.discovery_requests
    ALTER COLUMN email DROP NOT NULL,
    ADD COLUMN provider TEXT;
```

#### 6. Add StytchConfig.publicToken

Need the public token for client-side OAuth redirect URL.

**File: `external/stytch/src/main/kotlin/dev/template/stytch/StytchConfig.kt`**

```kotlin
data class StytchConfig(
    val projectId: String,
    val secret: String,
    val publicToken: String  // NEW - for OAuth redirect URLs
)
```

**Environment variable:** `STYTCH_PUBLIC_TOKEN`

---

## Part 2: SMS OTP (Magic SMS on Mobile)

### Important: SMS OTP is MFA in Stytch B2B

In Stytch B2B, SMS OTP is a **second factor**, not primary auth. The flow is:

```
Primary Auth (magic link/OAuth)
         │
         ▼
┌─────────────────────┐
│ intermediate_session│
│ (not full session)  │
└──────────┬──────────┘
           │ if MFA required/enabled
           ▼
┌─────────────────────┐
│  POST /otp/sms/send │
│  (sends code)       │
└──────────┬──────────┘
           │ user enters code
           ▼
┌─────────────────────┐
│ POST /otp/sms/auth  │
│ (validates code)    │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   Full session      │
│   (JWT cookie)      │
└─────────────────────┘
```

### Alternative: SMS OTP as Primary Auth (Consumer Pattern)

For mobile-first "magic SMS" as primary auth (like consumer apps), we have options:

**Option A: Use Stytch Consumer API** (separate from B2B)
- Different SDK, different endpoints
- True SMS-first auth without org context
- Would require parallel integration

**Option B: Trusted Auth Token pattern**
- We handle SMS ourselves (Twilio/etc)
- Verify phone, then mint Stytch session via Trusted Auth Token
- Full control, more work

**Option C: Use B2B Discovery with email + SMS MFA**
- User enters email → magic link sent
- After email verified, prompt for phone
- Send SMS OTP as MFA step
- Works within existing B2B flow

### Recommended: Option C for MVP

Leverage existing magic link flow, add SMS as MFA:

#### 1. Add OTP API wrapper (`external/stytch/`)

**File: `external/stytch/src/main/kotlin/dev/template/stytch/api/Otp.kt`**

```kotlin
object Otp {
    context(client: StytchB2BClient, _: Raise<StytchError>)
    fun smsSend(
        organizationId: String,
        memberId: String,
        phoneNumber: String?  // E.164 format, optional if member has phone
    ): SmsSendResponse

    context(client: StytchB2BClient, _: Raise<StytchError>)
    fun smsAuthenticate(
        organizationId: String,
        memberId: String,
        code: String,
        intermediateSessionToken: String
    ): SmsAuthenticateResponse
}
```

#### 2. Add MFA challenge flow

**File: `integrations/iam-stytch/.../mfa/SmsMfaChallenge.kt`**

Handles the intermediate state where user has verified email but needs SMS.

#### 3. Add phone number to User model

**Migration: `V{epoch}__iam__add-phone.sql`**

```sql
ALTER TABLE iam.users ADD COLUMN phone_number TEXT;
```

#### 4. Add MFA endpoints

**File: `apps/main/.../endpoints/Mfa.kt`**

```kotlin
"/mfa/sms/send" bind POST to { ... }      // Trigger SMS
"/mfa/sms/verify" bind POST to { ... }    // Verify code
```

#### 5. Update session flow

When `CompleteDiscoveryCallback` returns an intermediate session (MFA required):
- Don't create JWT yet
- Return response indicating MFA needed
- Client shows SMS input
- After SMS verified, create full JWT

---

## Configuration Changes

### New Environment Variables

| Variable | Description |
|----------|-------------|
| `STYTCH_PUBLIC_TOKEN` | Public token for OAuth redirect URLs |

### Stytch Dashboard Setup

1. **OAuth Providers**: Enable Google OAuth in Stytch dashboard
2. **Redirect URLs**: Add `{ORIGIN}/auth/callback` with query param template
3. **MFA Policy**: Configure SMS OTP if using MFA flow

---

## File Summary

### New Files

| Path | Purpose |
|------|---------|
| `external/stytch/src/main/kotlin/dev/template/stytch/api/OAuth.kt` | OAuth discovery authenticate |
| `external/stytch/src/main/kotlin/dev/template/stytch/api/Otp.kt` | SMS OTP send/authenticate |
| `integrations/iam-stytch/.../discovery/flows/RequestOAuthDiscovery.kt` | OAuth flow initiation |
| `integrations/iam-stytch/.../mfa/SmsMfaChallenge.kt` | MFA state management |
| `apps/main/.../endpoints/Mfa.kt` | MFA HTTP endpoints |
| `modules/iam/src/main/resources/db/migrate/iam/V{epoch}__iam__add-phone.sql` | Phone column |
| `integrations/iam-stytch/src/main/resources/db/migrate/iam_stytch/V{epoch}__iam_stytch__oauth-support.sql` | OAuth schema changes |

### Modified Files

| Path | Changes |
|------|---------|
| `external/stytch/src/main/kotlin/dev/template/stytch/StytchConfig.kt` | Add publicToken |
| `integrations/iam-stytch/.../discovery/actions/AuthenticateCallback.kt` | Handle discovery_oauth |
| `apps/main/src/main/kotlin/dev/template/app/endpoints/Login.kt` | Add `/google` route |
| `apps/main/src/main/kotlin/dev/template/app/AppConfig.kt` | Add STYTCH_PUBLIC_TOKEN |
| `modules/iam/src/main/kotlin/dev/template/iam/model/User.kt` | Add phoneNumber field |

---

## Implementation Order

### Phase 1: Google OAuth
1. Add `StytchConfig.publicToken` + env var
2. Add `OAuth.discoveryAuthenticate` API wrapper
3. Migration: make email nullable, add provider column
4. Add `RequestOAuthDiscovery` flow
5. Update `AuthenticateCallback` for discovery_oauth
6. Add `/login/google` endpoint
7. Test end-to-end

### Phase 2: SMS MFA
1. Add `Otp.smsSend` and `Otp.smsAuthenticate` wrappers
2. Migration: add phone_number to users
3. Add MFA challenge flow
4. Add `/mfa/sms/*` endpoints
5. Update callback to handle intermediate sessions
6. Test end-to-end

---

## Open Questions

1. **OAuth provider selection**: Start with Google only, or also Microsoft?
2. **MFA enforcement**: Optional or required after email verification?
3. **Phone number collection**: During signup, or lazy on first MFA prompt?
4. **Mobile client**: Native app or mobile web? (affects OAuth redirect handling)
