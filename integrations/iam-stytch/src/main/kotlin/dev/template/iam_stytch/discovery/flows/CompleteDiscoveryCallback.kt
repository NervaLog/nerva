package dev.template.iam_stytch.discovery.flows

import arrow.core.raise.context.Raise
import com.stytch.java.b2b.StytchB2BClient
import dev.template.iam.UserInfo
import dev.template.iam_stytch.DiscoveryRequestToken
import dev.template.iam_stytch.IamStytchError
import dev.template.iam_stytch.discovery.actions.ClaimDiscoveryRequest
import dev.template.iam_stytch.discovery.actions.AuthenticateCallback
import dev.template.iam_stytch.discovery.actions.ConfirmDiscoveryConsumed
import dev.template.iam_stytch.discovery.actions.EnsureAuthoritativeUserAndOrg
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.stytch.StytchRedirectToken

/**
 * Completes the discovery callback flow after user clicks magic link.
 *
 * 1. Claims the discovery request (validates PKCE, leases for processing)
 * 2. Authenticates with Stytch using the redirect token
 * 3. Creates or joins organization in Stytch
 * 4. Ensures user/org exist in PostgreSQL (authoritative source)
 * 5. Marks discovery request as consumed
 *
 * @return UserInfo for session creation
 */
object CompleteDiscoveryCallback {

    context(
        _: StytchB2BClient,
        _: PostgRestClient,
        _: Raise<IamStytchError>
    )
    operator fun invoke(
        discoveryToken: DiscoveryRequestToken,
        stytchToken: StytchRedirectToken
    ): UserInfo {
        val leaseOwner = stytchToken.value

        // 1. Claim request and get PKCE verifier
        val claim = ClaimDiscoveryRequest(discoveryToken, leaseOwner)

        // 2. Authenticate with Stytch
        val authResponse = AuthenticateCallback(stytchToken, claim.verifier)

        // 3. Create or join org in Stytch
        val createOrExchange = CreateStytchOrgAndOrLogUserIn(authResponse)

        // 4. Ensure user/org in PostgreSQL
        val userInfo = EnsureAuthoritativeUserAndOrg(createOrExchange)

        // 5. Mark discovery request as consumed
        ConfirmDiscoveryConsumed(claim.id, leaseOwner)

        return userInfo
    }
}
