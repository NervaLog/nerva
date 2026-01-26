# Stytch <-> our-IAM

Basic structure: user <=1:1=> org.

Primary source of truth: our database. If Stytch disagrees, we make Stytch agree.

---

## Discovery Flow (Magic Link Onboarding)

The discovery flow handles creator onboarding via Stytch B2B magic links. It uses PKCE for security and a distributed lease pattern for exactly-once processing.

### Flow Overview

```
┌──────────┐     ┌─────────┐     ┌──────────┐     ┌────────┐
│  Client  │────>│   App   │────>│  Stytch  │────>│  Email │
└──────────┘     └─────────┘     └──────────┘     └────────┘
                      │                                │
                      │ 1. RequestDiscovery            │
                      │    (stores PKCE verifier)      │
                      │                                │
                      │<───────────────────────────────┘
                      │ 2. User clicks magic link
                      │
                      │ 3. ClaimDiscoveryRequest
                      │    (lease for exactly-once)
                      │
                      │ 4. Exchange token with Stytch
                      │
                      │ 5. CreateUserAndOrg
                      │    (idempotent upsert)
                      │
                      │ 6. ConfirmDiscoveryConsumed
                      │    (mark complete)
                      └──────────────────────────────────>
```

### Actions

| Action | Description |
|--------|-------------|
| `RequestDiscovery` | Creates a PKCE-secured discovery request in the database, then calls Stytch to send the magic link email |
| `ClaimDiscoveryRequest` | Claims a pending request with a distributed lease (prevents double-processing from concurrent callbacks) |
| `CreateUserAndOrg` | Idempotently creates user, org, and membership using PostgreSQL upserts. Safe to call multiple times |
| `ConfirmDiscoveryConsumed` | Marks the request as consumed after successful user creation |

### Database Tables

**`iam_stytch.discovery_requests`** - Tracks magic link requests through their lifecycle

| Column | Description |
|--------|-------------|
| `id` | Request UUID |
| `request_id` | Stytch request ID for correlation |
| `email` | Target email address |
| `first_name` | Optional first name from discovery |
| `verifier` | PKCE verifier (stored server-side) |
| `code_challenge` | PKCE challenge (sent to Stytch) |
| `status` | `pending` → `claimed` → `consumed` |
| `lease_owner` | Worker ID holding the claim lease |
| `lease_expires_at` | Lease expiration for distributed locking |

### Security Properties

- **PKCE**: Code verifier never leaves the server; only the challenge is sent to Stytch
- **Distributed Lease**: `ClaimDiscoveryRequest` uses `FOR UPDATE SKIP LOCKED` to prevent race conditions
- **Idempotent Creation**: `CreateUserAndOrg` uses `ON CONFLICT DO UPDATE` so duplicate callbacks are safe
- **Lease Expiration**: Stale leases automatically expire, allowing retry by other workers

### Example Usage

```kotlin
context(stytch: StytchB2BClient, postgrest: PostgRestClient) {
    either {
        // 1. User submits email on login page
        RequestDiscovery(
            email = Email("creator@example.com"),
            redirectTo = Uri.of("https://app.example.com/auth/callback")
        )

        // ... user clicks magic link, Stytch redirects to callback ...

        // 2. Callback handler claims the request
        val claimed = ClaimDiscoveryRequest(
            token = tokenFromStytch,
            leaseOwner = "worker-${instanceId}"
        )

        // 3. Exchange with Stytch using PKCE verifier
        val authenticated = stytch.magicLinks.discovery.authenticate(
            token = tokenFromStytch,
            codeVerifier = claimed.verifier
        )

        // 4. Create user/org (idempotent)
        val userInfo = CreateUserAndOrg(
            provider = StytchIdentityTypes.stytch_magic_link,
            providerSubject = ProviderSubject(authenticated.memberId),
            email = claimed.email,
            firstName = authenticated.firstName,
            orgSlug = Slug.of(authenticated.orgName)
        )

        // 5. Mark consumed
        ConfirmDiscoveryConsumed(claimed.id, leaseOwner)

        userInfo
    }
}
```

### Cleanup

Expired and consumed discovery requests are cleaned up by `pg_cron`:

```sql
SELECT cron.schedule(
    'cleanup-discovery-requests',
    '*/15 * * * *',  -- every 15 minutes
    $$DELETE FROM iam_stytch.discovery_requests
      WHERE status = 'consumed'
         OR (status = 'pending' AND created_at < now() - interval '1 hour')$$
);
```

---

Cool — here’s a **PostgREST-first local session manager** that assumes:

* **Stytch verification happens outside Postgres** (edge/API gateway verifies `session_token` with Stytch).
* After verification, the gateway calls **PostgREST RPC** to **mint / refresh** a local session token that PostgREST can use for RLS context.

This gives you:

* Opaque local session token (not JWT) you can revoke instantly
* DB-native “set GUCs then run RLS” flow
* One clean place to handle org/role changes

---

## Request flow

### A) Create/refresh local session

1. Client presents Stytch session token to your gateway
2. Gateway verifies with Stytch, extracts:

    * `provider_user_id` (Stytch user id or member id)
    * `email`, `display_name`
    * `stytch_session_id`
    * `stytch_expires_at`
3. Gateway calls PostgREST:

`POST /rpc/session_upsert`

…and gets back:

* `local_session_token` (opaque bearer)
* `expires_at`
* `user_id`, `org_id`, `role`, `scopes`

### B) Use local session on PostgREST calls

Client calls PostgREST with:

`Authorization: Bearer <local_session_token>`

You implement a small Postgres function that:

* validates token
* sets `app.user_id`, `app.org_id`, `app.role`, `app.scopes`
* then your RLS policies use those settings

---

## Schema + functions (single migration chunk)

Assumes `pgcrypto` is available.

```sql
-- extensions
create extension if not exists pgcrypto;

-- schema for sessions
create schema if not exists app;

-- local sessions table
create table if not exists app.sessions (
  id uuid primary key default gen_random_uuid(),

  -- stable identity bindings
  user_id uuid not null,
  org_id  uuid not null,

  -- tie back to upstream auth lease (for revocation webhooks)
  stytch_session_id text not null unique,

  role text not null,
  scopes text[] not null default '{}',

  -- opaque token storage (store hash only)
  token_hash bytea not null unique,

  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),

  -- hard expiry must never exceed Stytch expiry
  expires_at timestamptz not null,

  revoked_at timestamptz,
  revoke_reason text
);

create index if not exists sessions_user_org_idx on app.sessions (user_id, org_id);
create index if not exists sessions_expires_at_idx on app.sessions (expires_at);
create index if not exists sessions_revoked_at_idx on app.sessions (revoked_at);

-- helper: hash a token
create or replace function app.hash_token(p_token text)
returns bytea
language sql
immutable
as $$
  select digest(p_token, 'sha256');
$$;

-- IMPORTANT:
-- session_upsert is called by your gateway after Stytch verification.
-- It mints a new local bearer token (or rotates the token), and clamps expiry.
create or replace function app.session_upsert(
  p_stytch_session_id text,
  p_user_id uuid,
  p_org_id uuid,
  p_role text,
  p_scopes text[],
  p_stytch_expires_at timestamptz,
  p_local_ttl_seconds integer default 3600
) returns jsonb
language plpgsql
security definer
as $$
declare
  v_now timestamptz := now();
  v_local_token text := encode(gen_random_bytes(32), 'hex');
  v_token_hash bytea := app.hash_token(v_local_token);
  v_expires_at timestamptz;
  v_session_id uuid;
begin
  -- clamp local expiry to both app TTL and upstream expiry
  v_expires_at := least(
    p_stytch_expires_at,
    v_now + make_interval(secs => greatest(p_local_ttl_seconds, 60))
  );

  -- If existing session exists for this stytch_session_id, rotate token + refresh context
  insert into app.sessions (
    stytch_session_id,
    user_id, org_id,
    role, scopes,
    token_hash,
    created_at, last_seen_at,
    expires_at
  )
  values (
    p_stytch_session_id,
    p_user_id, p_org_id,
    p_role, coalesce(p_scopes, '{}'),
    v_token_hash,
    v_now, v_now,
    v_expires_at
  )
  on conflict (stytch_session_id) do update
  set
    user_id = excluded.user_id,
    org_id = excluded.org_id,
    role = excluded.role,
    scopes = excluded.scopes,
    token_hash = excluded.token_hash,
    last_seen_at = excluded.last_seen_at,
    expires_at = excluded.expires_at,
    revoked_at = null,
    revoke_reason = null
  returning id into v_session_id;

  return jsonb_build_object(
    'session_id', v_session_id,
    'local_session_token', v_local_token,
    'expires_at', v_expires_at,
    'user_id', p_user_id,
    'org_id', p_org_id,
    'role', p_role,
    'scopes', coalesce(p_scopes, '{}')
  );
end;
$$;

-- validate token + return session context (and optionally slide last_seen)
create or replace function app.session_validate(
  p_local_session_token text,
  p_touch boolean default true
) returns table(
  session_id uuid,
  user_id uuid,
  org_id uuid,
  role text,
  scopes text[],
  expires_at timestamptz
)
language plpgsql
security definer
as $$
declare
  v_now timestamptz := now();
  v_hash bytea := app.hash_token(p_local_session_token);
begin
  return query
  select s.id, s.user_id, s.org_id, s.role, s.scopes, s.expires_at
  from app.sessions s
  where s.token_hash = v_hash
    and s.revoked_at is null
    and s.expires_at > v_now;

  if p_touch then
    update app.sessions
    set last_seen_at = v_now
    where token_hash = v_hash
      and revoked_at is null
      and expires_at > v_now;
  end if;
end;
$$;

-- revoke by local token (client logout)
create or replace function app.session_revoke(
  p_local_session_token text,
  p_reason text default 'logout'
) returns jsonb
language plpgsql
security definer
as $$
declare
  v_hash bytea := app.hash_token(p_local_session_token);
  v_now timestamptz := now();
  v_count int;
begin
  update app.sessions
  set revoked_at = v_now,
      revoke_reason = p_reason
  where token_hash = v_hash
    and revoked_at is null;

  get diagnostics v_count = row_count;

  return jsonb_build_object('revoked', (v_count > 0));
end;
$$;

-- revoke by stytch session id (webhook handler path)
create or replace function app.session_revoke_by_stytch(
  p_stytch_session_id text,
  p_reason text default 'stytch_revoked'
) returns jsonb
language plpgsql
security definer
as $$
declare
  v_now timestamptz := now();
  v_count int;
begin
  update app.sessions
  set revoked_at = v_now,
      revoke_reason = p_reason
  where stytch_session_id = p_stytch_session_id
    and revoked_at is null;

  get diagnostics v_count = row_count;
  return jsonb_build_object('revoked', (v_count > 0));
end;
$$;

-- helper: set RLS context GUCs for the *current transaction*
create or replace function app.set_request_context(
  p_user_id uuid,
  p_org_id uuid,
  p_role text,
  p_scopes text[]
) returns void
language plpgsql
security definer
as $$
begin
  perform set_config('app.user_id', p_user_id::text, true);
  perform set_config('app.org_id',  p_org_id::text,  true);
  perform set_config('app.role',    p_role,          true);
  perform set_config('app.scopes',  array_to_string(coalesce(p_scopes,'{}'), ','), true);
end;
$$;
```

---

## PostgREST wiring pattern

### Endpoint: `/rpc/session_upsert`

* Called only by your gateway (service role / restricted key)
* Returns the token to the client

### Endpoint: `/rpc/session_validate`

* You probably **don’t expose this** directly to the client
* Instead, you use it in an **auth hook** / request prelude (see below)

### Using token to drive RLS in PostgREST

PostgREST typically wants JWT to set role/claims automatically. If you don’t want JWT, you’ve got two common options:

1. **Gateway proxy mode (simple + clean)**
   Client always talks to your gateway, gateway:

    * validates local token via `/rpc/session_validate`
    * calls `app.set_request_context(...)` inside the same DB transaction (or uses a dedicated DB role with set_config)
    * then calls PostgREST / tables
      This gives you perfect control and keeps PostgREST “dumb”.

2. **JWT-lite for PostgREST only (still DB is truth)**
   You still mint the opaque session token as above, but your gateway also returns a short-lived PostgREST JWT whose only “claim” is `session_id`; PostgREST pre-request function loads context from `app.sessions`.
   This is extra moving parts but avoids proxying all requests.

Given your “PG is source of truth” vibe, (1) is usually the least surprising.

---

## RLS usage (example)

```sql
alter table iam.org_memberships enable row level security;

create policy org_memberships_by_org
on iam.org_memberships
using (org_id = current_setting('app.org_id')::uuid);
```

…and you can add role/scopes checks similarly.

---

## Operational bits you’ll want next

* **Membership change invalidation**

    * On role/org membership change: revoke all sessions for that `(user_id, org_id)`
* **Cleanup job**

    * `delete from app.sessions where revoked_at is not null or expires_at < now() - interval '7 days';`
    * run via `pg_cron`

---

Yep — that separation buys you *clean invariants*:

* **Stytch token = proof of identity lease**
* **Local token = capability to operate in *your* tenancy/role model**
* PostgREST only ever sees the second one, so it never “accidentally” couples to an external auth lifecycle.

If you want to make this extra tight (and very PostgREST-native), here are the two upgrades I’d bake in immediately:

## 1) Gateway sends only Stytch identity, DB derives org/role/scopes

Instead of your gateway passing `user_id/org_id/role/scopes` into `session_upsert`, make it pass *only* what it can prove:

* `p_provider` (e.g. `'stytch'`)
* `p_provider_user_id` (or member id)
* `p_stytch_session_id`
* `p_stytch_expires_at`
* maybe `p_email`, `p_display_name` (helpful for first-seen creation)

Then Postgres does:

1. upsert user (by provider id)
2. pick org context (primary org or requested org slug)
3. read membership → role/scopes
4. mint local token

That keeps your gateway stateless and makes “DB is source of truth” literal.

## 2) Rotate local tokens on every exchange (no long-lived bearer)

Treat the local token as a **one-hour capability**, rotated whenever:

* user hits “refresh session”
* you see “last_seen” older than N minutes
* membership changes (forced rotation/revoke)

This keeps replay windows small while still being cheap.

---

### Tiny “shape” for the v2 RPC

`POST /rpc/session_exchange`

**Input**

* `stytch_session_id`
* `provider_user_id`
* `stytch_expires_at`
* optional: `org_slug` (if user is switching orgs)

**Output**

* `local_session_token`
* `expires_at`
* `org_id/org_slug`
* `role/scopes`
* `user_id`