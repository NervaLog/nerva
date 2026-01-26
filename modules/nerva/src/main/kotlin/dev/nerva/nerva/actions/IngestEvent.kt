@file:Suppress("PropertyName")

package dev.nerva.nerva.actions

import arrow.core.raise.Raise
import com.fasterxml.jackson.databind.JsonNode
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.RpcPost
import dev.dailywombat.postgrest.actions.Select
import dev.nerva.nerva.NervaSchema
import dev.nerva.nerva.enums.AttentionKind
import dev.nerva.nerva.enums.EventType
import org.http4k.format.Jackson
import java.time.Instant
import java.util.*

data class IngestEventInput(
    val orgId: UUID,
    val provider: String,
    val externalId: String,
    val eventType: EventType,
    val payload: JsonNode? = null,
    val occurredAt: Instant? = null,
    val collapseKey: String? = null,
    val collapseWindowMinutes: Int = 5,
    val attentionKind: AttentionKind = AttentionKind.BATCH,
    val title: String? = null,
    val body: String? = null,
    val deeplinkUrl: String? = null,
    val expiresAt: Instant? = null
)

data class IngestEventResult(
    val event_id: UUID,
    val attention_id: UUID?,
    val was_created: Boolean,
    val job_id: UUID?
)

object IngestEvent {

    private data class Args(
        val p_org_id: String,
        val p_provider: String,
        val p_external_id: String,
        val p_event_type: String,
        val p_payload: JsonNode?,
        val p_occurred_at: String?,
        val p_collapse_key: String?,
        val p_collapse_window_minutes: Int,
        val p_attention_kind: String,
        val p_title: String?,
        val p_body: String?,
        val p_deeplink_url: String?,
        val p_expires_at: String?
    )

    private val resultLens = Jackson.autoBody<IngestEventResult>().toLens()

    context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
    operator fun invoke(input: IngestEventInput): IngestEventResult {
        val args = Args(
            p_org_id = input.orgId.toString(),
            p_provider = input.provider,
            p_external_id = input.externalId,
            p_event_type = input.eventType.value,
            p_payload = input.payload,
            p_occurred_at = input.occurredAt?.toString(),
            p_collapse_key = input.collapseKey,
            p_collapse_window_minutes = input.collapseWindowMinutes,
            p_attention_kind = input.attentionKind.value,
            p_title = input.title,
            p_body = input.body,
            p_deeplink_url = input.deeplinkUrl,
            p_expires_at = input.expiresAt?.toString()
        )

        return context(resultLens) {
            pgRest(NervaSchema.IngestEvent, RpcPost(args) {
                contentProfile(NervaSchema)
                accept(Select.Accept.SingularRepresentation)
            })
        }
    }
}
