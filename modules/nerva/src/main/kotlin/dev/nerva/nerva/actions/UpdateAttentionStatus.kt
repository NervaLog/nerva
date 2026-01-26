package dev.nerva.nerva.actions

import arrow.core.raise.Raise
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.Update
import dev.dailywombat.postgrest.headers.Prefer.Return
import dev.nerva.nerva.NervaSchema
import dev.nerva.nerva.enums.AttentionStatus
import dev.nerva.nerva.models.AttentionItem
import org.http4k.format.Jackson
import java.time.Instant
import java.util.*

object UpdateAttentionStatus {

    private val listLens = Jackson.autoBody<List<AttentionItem>>().toLens()

    context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
    operator fun invoke(
        id: UUID,
        status: AttentionStatus,
        deliveredAt: Instant? = null,
        actionedAt: Instant? = null
    ): Unit = context(listLens) {
        pgRest(NervaSchema.AttentionProjection, Update<AttentionItem> {
            contentProfile(NervaSchema)
            returning(Return.Representation)
            where {
                eq(AttentionItem::id, id)
            }
            set {
                AttentionItem::status set status.value
                AttentionItem::updated_at set Instant.now()
                if (deliveredAt != null) {
                    AttentionItem::delivered_at set deliveredAt
                }
                if (actionedAt != null) {
                    AttentionItem::actioned_at set actionedAt
                }
            }
        })
        Unit
    }
}
