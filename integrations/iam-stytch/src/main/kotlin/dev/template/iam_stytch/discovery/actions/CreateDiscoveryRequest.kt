package dev.template.iam_stytch.discovery.actions

import arrow.core.raise.context.Raise
import arrow.core.raise.context.withError
import dev.template.iam_stytch.IamStytchError
import dev.template.iam_stytch.IamStytchSchema
import dev.template.iam_stytch.IamStytchSchema.DiscoveryRequests
import dev.template.iam_stytch.discovery.models.DiscoveryFingerprints
import dev.template.iam_stytch.discovery.models.DiscoveryRequest
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.actions.Insert
import dev.dailywombat.postgrest.actions.Select.Accept
import dev.dailywombat.postgrest.headers.Prefer.Return
import dev.dailywombat.utils.Email

object CreateDiscoveryRequest {

    /** Create discovery request for magic link */
    context(
        pgRest: PostgRestClient,
        _: Raise<IamStytchError>
    )
    operator fun invoke(
        email: Email,
        firstName: String?,
        fingerprints: DiscoveryFingerprints
    ) = withError(IamStytchError::PostgRest) {
        context(DiscoveryRequest.lens) {
            val dr = DiscoveryRequest.forMagicLink(email, firstName, fingerprints)
            pgRest(DiscoveryRequests, Insert(dr) {
                contentProfile(IamStytchSchema)
                returning(Return.Representation)
                accept(Accept.SingularRepresentation)
            })
        }
    }

    /** Create discovery request for OAuth */
    context(
        pgRest: PostgRestClient,
        _: Raise<IamStytchError>
    )
    fun forOAuth(
        provider: String,
        fingerprints: DiscoveryFingerprints
    ) = withError(IamStytchError::PostgRest) {
        context(DiscoveryRequest.lens) {
            val dr = DiscoveryRequest.forOAuth(provider, fingerprints)
            pgRest(DiscoveryRequests, Insert(dr) {
                contentProfile(IamStytchSchema)
                returning(Return.Representation)
                accept(Accept.SingularRepresentation)
            })
        }
    }
}