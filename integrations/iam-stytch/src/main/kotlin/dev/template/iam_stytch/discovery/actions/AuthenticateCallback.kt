package dev.template.iam_stytch.discovery.actions

import arrow.core.raise.context.Raise
import arrow.core.raise.context.raise
import arrow.core.raise.context.withError
import com.stytch.java.b2b.StytchB2BClient
import com.stytch.java.b2b.models.magiclinksdiscovery.AuthenticateResponse
import dev.template.iam_stytch.IamStytchError
import dev.dailywombat.stytch.Pkce
import dev.dailywombat.stytch.StytchRedirectToken
import dev.dailywombat.stytch.StytchRedirectToken.Companion.TokenType
import dev.dailywombat.stytch.api.MagicLinks
import dev.dailywombat.stytch.api.OAuth

internal object AuthenticateCallback {

    /**
     * Authenticate with Stytch based on token type.
     * Returns the same response shape for both magic link and OAuth discovery.
     */
    context(
        _: StytchB2BClient,
        _: Raise<IamStytchError>
    )
    operator fun invoke(
        token: StytchRedirectToken,
        codeVerifier: Pkce.CodeVerifier
    ): AuthenticateResponse = withError(IamStytchError::Stytch) {
        when (token.type) {
            TokenType.discovery -> MagicLinks.discoveryAuthenticate(token, codeVerifier)
            TokenType.discovery_oauth -> {
                val oauthResponse = OAuth.discoveryAuthenticate(token, codeVerifier)
                // Convert OAuth response to the same shape as magic link response
                AuthenticateResponse(
                    requestId = oauthResponse.requestId,
                    intermediateSessionToken = oauthResponse.intermediateSessionToken,
                    emailAddress = oauthResponse.emailAddress,
                    discoveredOrganizations = oauthResponse.discoveredOrganizations,
                    statusCode = oauthResponse.statusCode
                )
            }
            else -> raise(IamStytchError.UnsupportedTokenType(token.type))
        }
    }
}