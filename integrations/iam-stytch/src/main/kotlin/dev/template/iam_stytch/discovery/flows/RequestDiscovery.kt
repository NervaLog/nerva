package dev.template.iam_stytch.discovery.flows

import arrow.core.raise.context.Raise
import com.stytch.java.b2b.StytchB2BClient
import dev.template.iam_stytch.IamStytchError
import dev.template.iam_stytch.discovery.actions.CreateDiscoveryRequest
import dev.template.iam_stytch.discovery.actions.SendMagicLink
import dev.template.iam_stytch.discovery.models.DiscoveryRequest
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.utils.Email
import org.http4k.core.Uri


/**
 * Call this to initiate a Stytch discovery process by magic link.
 * @see [https://stytch.com/docs/b2b/guides/magic-links/overview]
 */
object RequestDiscovery {

    context(
        _: StytchB2BClient,
        _: PostgRestClient,
        _: Raise<IamStytchError>
    )
    operator fun invoke(
        email: Email,
        firstName: String? = null,
        redirectTo: Uri
    ): DiscoveryRequest {
        val fingerprints = SendMagicLink(email, redirectTo)
        return CreateDiscoveryRequest(email, firstName, fingerprints)
    }
}