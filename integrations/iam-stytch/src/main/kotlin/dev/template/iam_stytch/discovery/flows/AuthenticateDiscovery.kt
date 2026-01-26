package dev.template.iam_stytch.discovery.flows

import arrow.core.raise.context.Raise
import com.stytch.java.b2b.StytchB2BClient
import com.stytch.java.b2b.models.magiclinksdiscovery.AuthenticateResponse
import dev.template.iam_stytch.DiscoveryRequestToken
import dev.template.iam_stytch.IamStytchError
import dev.template.iam_stytch.discovery.actions.AuthenticateCallback
import dev.template.iam_stytch.discovery.actions.ClaimDiscoveryRequest
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.stytch.StytchRedirectToken

object AuthenticateDiscovery {

    context(
        _: StytchB2BClient,
        _: PostgRestClient,
        _: Raise<IamStytchError>
    )
    operator fun invoke(
        token: DiscoveryRequestToken,
        stytchRedirectToken: StytchRedirectToken
    ): AuthenticateResponse {
        //  Lease request if exists and authenticate against Stytch.
        //  Leases will fail at stored proc level if consistency doesn't check out.
        val leaseOwner = stytchRedirectToken.value

        val claim = ClaimDiscoveryRequest(token, leaseOwner)
        return AuthenticateCallback(stytchRedirectToken, codeVerifier = claim.verifier)
    }
}