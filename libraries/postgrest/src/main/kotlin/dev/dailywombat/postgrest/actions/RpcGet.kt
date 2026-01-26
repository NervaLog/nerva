package dev.dailywombat.postgrest.actions

import dev.dailywombat.postgrest.PostgRestAction
import org.http4k.core.Method
import org.http4k.core.Request
import org.http4k.core.Uri
import org.http4k.format.Jackson.asJsonObject

class RpcGet<R : Any> private constructor(
    private val params: R?,
    private val accept: List<String>,
    private val profile: String?
) : PostgRestAction<R> {

    override fun toRequest(baseUri: Uri, entity: String): Request {
        val uri = Uri.of("$baseUri/rpc/$entity")
        var req = Request(Method.GET, uri)

        // For GET RPC, parameters must be query params.
        // We can convert the DTO to a map of strings.
        params?.let {
            val queryParams = it.asQueryMap()
            req = queryParams.entries.fold(req) { acc, (key, value) ->
                acc.query(key, value)
            }
        }

        if (accept.isNotEmpty()) req = req.header("Accept", accept.joinToString(", "))
        if (!profile.isNullOrBlank()) req = req.header("Content-Profile", profile)

        return req
    }

    /**
     * Helper to convert the DTO to a Map for Query Parameters.
     * Uses Jackson to ensure naming conventions (Snake Case, etc.) are respected.
     */
    private fun R.asQueryMap(): Map<String, String> =
        asJsonObject(this)
            .fields()
            .asSequence()
            .associate { it.key to it.value.asText() }

    class Builder<R : Any> {
        private var params: R? = null
        private val accept = mutableListOf<String>()
        private var profile: String? = null

        fun params(value: R) = apply { params = value }
        fun accept(vararg values: String) = apply { accept += values }
        fun profile(value: String) = apply { profile = value }

        fun build(): RpcGet<R> = RpcGet(
            params = params,
            accept = accept.toList(),
            profile = profile
        )
    }

    companion object {
        inline operator fun <reified R : Any> invoke(
            params: R,
            noinline block: Builder<R>.() -> Unit = {}
        ): RpcGet<R> =
            Builder<R>()
                .apply { params(params) }
                .apply(block)
                .build()

        inline operator fun <reified R : Any> invoke(
            noinline block: Builder<R>.() -> Unit
        ): RpcGet<R> =
            Builder<R>()
                .apply(block)
                .build()
    }
}