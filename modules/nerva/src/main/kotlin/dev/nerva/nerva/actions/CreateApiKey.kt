package dev.nerva.nerva.actions

import arrow.core.raise.Raise
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.Insert
import dev.nerva.nerva.NervaSchema
import dev.nerva.nerva.models.ApiKey
import org.http4k.format.Jackson
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.*

data class CreateApiKeyInput(
    val orgId: UUID,
    val name: String,
    val description: String? = null,
    val scopes: List<String> = emptyList()
)

data class CreateApiKeyResult(
    val apiKey: String,  // Full key (only returned once)
    val keyId: UUID,
    val keyPrefix: String
)

object CreateApiKey {

    private val random = SecureRandom()
    private val listLens = Jackson.autoBody<List<ApiKey>>().toLens()

    context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
    operator fun invoke(input: CreateApiKeyInput): CreateApiKeyResult {
        // Generate a random API key: nv_ + 32 random bytes (base64url)
        val keyBytes = ByteArray(32)
        random.nextBytes(keyBytes)
        val keyBody = Base64.getUrlEncoder().withoutPadding().encodeToString(keyBytes)
        val fullKey = "nv_$keyBody"

        // Extract prefix for display (nv_ + first 8 chars of body = 11 total)
        val keyPrefix = fullKey.take(11)

        // Hash the full key for storage (hex encoding to match PG's encode(digest(...), 'hex'))
        val keyHash = MessageDigest.getInstance("SHA-256")
            .digest(fullKey.toByteArray())
            .joinToString("") { "%02x".format(it) }

        // Insert the key
        data class InsertBody(
            val org_id: UUID,
            val key_prefix: String,
            val key_hash: String,
            val name: String,
            val description: String?,
            val scopes: List<String>
        )

        val inserted = context(listLens) {
            pgRest(NervaSchema.ApiKeys, Insert(
                InsertBody(
                    org_id = input.orgId,
                    key_prefix = keyPrefix,
                    key_hash = keyHash,
                    name = input.name,
                    description = input.description,
                    scopes = input.scopes
                )
            ) {
                contentProfile(NervaSchema)
            })
        }

        return CreateApiKeyResult(
            apiKey = fullKey,
            keyId = inserted.first().id,
            keyPrefix = inserted.first().key_prefix
        )
    }
}
