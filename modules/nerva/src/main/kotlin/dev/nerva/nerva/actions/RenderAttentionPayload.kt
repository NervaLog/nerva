@file:Suppress("PropertyName")

package dev.nerva.nerva.actions

import arrow.core.raise.Raise
import com.fasterxml.jackson.databind.JsonNode
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.RpcPost
import dev.dailywombat.postgrest.actions.Select
import dev.nerva.nerva.NervaSchema
import org.http4k.format.Jackson
import java.util.*

object RenderAttentionPayload {

    private data class Args(val p_attention_id: String)

    private val payloadLens = Jackson.autoBody<JsonNode>().toLens()

    context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
    operator fun invoke(attentionId: UUID): JsonNode {
        return context(payloadLens) {
            pgRest(NervaSchema.RenderAttentionPayload, RpcPost(Args(attentionId.toString())) {
                contentProfile(NervaSchema)
                accept(Select.Accept.SingularRepresentation)
            })
        }
    }
}
