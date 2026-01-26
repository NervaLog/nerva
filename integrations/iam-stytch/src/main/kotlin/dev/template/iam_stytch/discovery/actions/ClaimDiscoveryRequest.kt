@file:Suppress("PropertyName")

package dev.template.iam_stytch.discovery.actions

import arrow.core.raise.context.Raise
import arrow.core.raise.context.withError
import dev.template.iam_stytch.DiscoveryRequestToken
import dev.template.iam_stytch.IamStytchError
import dev.template.iam_stytch.IamStytchSchema
import dev.template.iam_stytch.IamStytchSchema.ClaimDiscoveryRequest
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.actions.RpcPost
import dev.dailywombat.postgrest.actions.Select.Accept
import dev.dailywombat.stytch.Pkce
import dev.dailywombat.utils.Email
import org.http4k.format.Jackson
import java.time.Instant
import java.util.*

internal object ClaimDiscoveryRequest {

    private data class Args(
        val p_token: String,
        val p_lease_seconds: Int = 60,
        val p_lease_owner: String
    )

    data class Claimed(
        val id: UUID,
        val email: Email?,  // Nullable for OAuth flows where email comes from provider
        val first_name: String?,
        val verifier: Pkce.CodeVerifier,
        val code_challenge: Pkce.CodeChallenge,
        val lease_expires_at: Instant? = null,
    ) {
        companion object {
            val lens = Jackson.autoBody<Claimed>().toLens()
        }
    }

    context(
        pgRest: PostgRestClient,
        _: Raise<IamStytchError>
    )
    operator fun invoke(
        token: DiscoveryRequestToken,
        leaseOwner: String
    ) = withError(IamStytchError::PostgRest) {
        context(Claimed.lens) {
            val params = Args(p_token = token.value, p_lease_owner = leaseOwner)
            pgRest(ClaimDiscoveryRequest, RpcPost(params) {
                contentProfile(IamStytchSchema)
                accept(Accept.SingularRepresentation)
            }
            )
        }
    }
}