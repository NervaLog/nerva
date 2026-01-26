@file:Suppress("PropertyName")

package dev.nerva.nerva.actions

import arrow.core.raise.Raise
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.RpcPost
import dev.dailywombat.postgrest.actions.Select
import dev.nerva.nerva.NervaSchema
import org.http4k.format.Jackson
import java.util.*

sealed class ApiKeyValidation {
    data class Valid(
        val orgId: UUID,
        val keyId: UUID,
        val scopes: List<String>
    ) : ApiKeyValidation()

    data class Invalid(val error: String) : ApiKeyValidation()
}

object ValidateApiKey {

    private data class Args(val p_api_key: String)

    private data class RawResult(
        val valid: Boolean,
        val org_id: UUID? = null,
        val key_id: UUID? = null,
        val scopes: List<String>? = null,
        val error: String? = null
    )

    private val resultLens = Jackson.autoBody<RawResult>().toLens()

    context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
    operator fun invoke(apiKey: String): ApiKeyValidation {
        val raw = context(resultLens) {
            pgRest(NervaSchema.ValidateApiKey, RpcPost(Args(apiKey)) {
                contentProfile(NervaSchema)
                accept(Select.Accept.SingularRepresentation)
            })
        }

        return if (raw.valid && raw.org_id != null && raw.key_id != null) {
            ApiKeyValidation.Valid(
                orgId = raw.org_id,
                keyId = raw.key_id,
                scopes = raw.scopes ?: emptyList()
            )
        } else {
            ApiKeyValidation.Invalid(raw.error ?: "unknown_error")
        }
    }
}
