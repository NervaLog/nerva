@file:Suppress("PropertyName")

package dev.template.iam_stytch.discovery.actions

import arrow.core.raise.context.Raise
import arrow.core.raise.context.withError
import dev.template.iam_stytch.IamStytchError
import dev.template.iam_stytch.IamStytchSchema
import dev.template.iam_stytch.IamStytchSchema.ConfirmDiscoveryConsumed
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.actions.RpcPost
import dev.dailywombat.utils.http4k.Lenses
import java.util.*

internal object ConfirmDiscoveryConsumed {

    private data class Args(
        val p_id: UUID,
        val p_lease_owner: String
    )

    context(
        pgRest: PostgRestClient,
        _: Raise<IamStytchError>
    )
    operator fun invoke(
        discoveryRequestId: UUID,
        leaseOwner: String
    ) = withError(IamStytchError::PostgRest) {
        context(Lenses.unitEx) {
            val args = Args(
                p_id = discoveryRequestId,
                p_lease_owner = leaseOwner
            )
            pgRest(ConfirmDiscoveryConsumed, RpcPost(args) {
                contentProfile(IamStytchSchema)
            })
        }
    }
}