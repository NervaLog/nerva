package dev.template.iam_stytch.discovery.flows

import arrow.core.raise.context.Raise
import arrow.core.raise.context.withError
import dev.template.iam_stytch.DiscoveryRequestToken
import dev.template.iam_stytch.IamStytchError
import dev.template.iam_stytch.discovery.actions.CreateDiscoveryRequest
import dev.template.iam_stytch.discovery.models.DiscoveryFingerprints
import dev.template.iam_stytch.discovery.models.DiscoveryRequest
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.stytch.Pkce
import dev.dailywombat.stytch.Stytch.OpaqueTokenQueryParamName
import dev.dailywombat.stytch.StytchConfig
import org.http4k.core.Uri
import org.http4k.core.query

/**
 * OAuth provider for discovery flow.
 */
enum class OAuthProvider(val stytchName: String) {
    GOOGLE("google"),
    MICROSOFT("microsoft");
}

/**
 * Result of initiating OAuth discovery - contains the URL to redirect user to.
 */
data class OAuthDiscoveryRedirect(
    val redirectUrl: Uri,
    val discoveryRequest: DiscoveryRequest
)

/**
 * Initiate OAuth discovery flow.
 *
 * Unlike magic link discovery, this doesn't call Stytch API.
 * Instead, it:
 * 1. Generates PKCE verifier/challenge
 * 2. Creates discovery_request in DB (stores verifier for later verification)
 * 3. Builds and returns the Stytch OAuth start URL
 *
 * The client should redirect the user to the returned URL.
 *
 * @see [https://stytch.com/docs/b2b/api/oauth-google-discovery-start]
 */
object RequestOAuthDiscovery {

    context(
        _: PostgRestClient,
        _: Raise<IamStytchError>
    )
    operator fun invoke(
        provider: OAuthProvider,
        redirectTo: Uri,
        stytchConfig: StytchConfig
    ): OAuthDiscoveryRedirect {
        // 1. Generate PKCE
        val verifier = Pkce.generateVerifier()
        val challenge = withError(IamStytchError::Stytch) {
            Pkce.encodeChallenge(verifier)
        }

        // 2. Create opaque token for round-trip
        val opaqueToken = DiscoveryRequestToken()
        val redirectToWithToken = redirectTo.query(OpaqueTokenQueryParamName, opaqueToken.value)

        // 3. Create discovery request in DB
        val fingerprints = DiscoveryFingerprints(
            verifier = verifier,
            codeChallenge = challenge,
            token = opaqueToken,
            redirectTo = redirectToWithToken,
        )
        val discoveryRequest = CreateDiscoveryRequest.forOAuth(
            provider = provider.stytchName + "_oauth",
            fingerprints = fingerprints
        )

        // 4. Build Stytch OAuth start URL
        // Format: https://test.stytch.com/v1/b2b/public/oauth/{provider}/discovery/start
        val stytchBaseUrl = "${stytchConfig.publicBaseUrl}/v1/b2b/public/oauth/${provider.stytchName}/discovery/start"
        val oauthStartUrl = Uri.of(stytchBaseUrl)
            .query("public_token", stytchConfig.publicToken)
            .query("pkce_code_challenge", challenge.value)
            .query("discovery_redirect_url", redirectToWithToken.toString())

        return OAuthDiscoveryRedirect(
            redirectUrl = oauthStartUrl,
            discoveryRequest = discoveryRequest
        )
    }
}
