package dev.template.iam_stytch.discovery.actions

import arrow.core.raise.context.Raise
import arrow.core.raise.context.withError
import com.stytch.java.b2b.StytchB2BClient
import dev.template.iam_stytch.DiscoveryRequestToken
import dev.template.iam_stytch.IamStytchError
import dev.template.iam_stytch.discovery.models.DiscoveryFingerprints
import dev.dailywombat.stytch.Pkce
import dev.dailywombat.stytch.RequestId
import dev.dailywombat.stytch.Stytch.OpaqueTokenQueryParamName
import dev.dailywombat.stytch.api.MagicLinks
import dev.dailywombat.utils.Email
import org.http4k.core.Uri
import org.http4k.core.query

internal object SendMagicLink {

    context(
        _: StytchB2BClient,
        _: Raise<IamStytchError>
    )
    operator fun invoke(
        email: Email,
        redirectTo: Uri
    ): DiscoveryFingerprints {
        val verifier = Pkce.generateVerifier()
        val challenge = withError(IamStytchError::Stytch) {
            Pkce.encodeChallenge(verifier)
        }
        val opaqueToken = DiscoveryRequestToken()
        val redirectToWithToken = redirectTo.query(
            OpaqueTokenQueryParamName,
            opaqueToken.value
        )

        val (requestId, _) = withError(IamStytchError::Stytch) {
            MagicLinks.emailDiscoverySend(
                email,
                pkceCodeChallenge = challenge,
                redirectToWithToken,
                opaqueToken.value,
            )
        }

        return DiscoveryFingerprints(
            verifier = verifier,
            codeChallenge = challenge,
            requestId = RequestId(requestId),
            redirectTo = redirectToWithToken,
            token = opaqueToken,
        )
    }
}