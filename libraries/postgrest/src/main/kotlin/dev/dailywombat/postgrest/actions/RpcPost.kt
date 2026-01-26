package dev.dailywombat.postgrest.actions

import dev.dailywombat.flyway.modules.ModuleSchema
import dev.dailywombat.postgrest.PostgRestAction
import dev.dailywombat.postgrest.headers.Prefer
import org.http4k.core.Method
import org.http4k.core.Request
import org.http4k.core.Uri
import org.http4k.format.Jackson
import org.http4k.lens.BiDiBodyLens
import org.http4k.lens.LensInjector

class RpcPost<R : Any> private constructor(
    private val params: R?,
    private val injector: LensInjector<R, Request>?,
    private val accept: List<String>,
    private val contentProfile: String?,
    private val `return`: Prefer.Return?
) : PostgRestAction<R> {

    override fun toRequest(baseUri: Uri, entity: String): Request {
        // PostgREST RPCs are reached at /rpc/function_name
        var req = Request(Method.POST, Uri.of("$baseUri/rpc/$entity"))

        // Inject body if parameters are provided
        if (params != null && injector != null) {
            req = injector(params, req)
        }

        val prefer = buildList {
            `return`?.let { add(it.value) }
        }.joinToString(", ")

        if (prefer.isNotEmpty()) req = req.header("Prefer", prefer)
        if (accept.isNotEmpty()) req = req.header("Accept", accept.joinToString(", "))
        if (!contentProfile.isNullOrBlank()) req = req.header("Content-Profile", contentProfile)

        return req
    }

    class Builder<R : Any>(
        private val defaultBody: BiDiBodyLens<R>
    ) {
        private var params: R? = null
        private var injector: LensInjector<R, Request>? = null
        private val accept = mutableListOf<String>()
        private var contentProfile: String? = null
        private var returning: Prefer.Return? = null

        fun params(value: R) = apply { params = value }
        fun injector(value: LensInjector<R, Request>) = apply { injector = value }
        fun body(lens: BiDiBodyLens<R>) = apply { injector = lens }

        fun accept(vararg values: String) = apply { accept += values }
        fun contentProfile(value: ModuleSchema) = apply { contentProfile = value.name }
        fun returning(value: Prefer.Return) = apply { returning = value }

        fun build(): RpcPost<R> {
            // injector defaults to Jackson lens if params are present but injector isn't explicitly set
            val inj = if (params != null) (injector ?: defaultBody) else null
            return RpcPost(
                params = params,
                injector = inj,
                accept = accept.toList(),
                contentProfile = contentProfile,
                `return` = returning
            )
        }
    }

    companion object {
        // Entrypoint for RPCs with arguments
        inline operator fun <reified R : Any> invoke(
            params: R,
            noinline block: Builder<R>.() -> Unit = {}
        ): RpcPost<R> =
            Builder(Jackson.autoBody<R>().toLens())
                .apply { params(params) }
                .apply(block)
                .build()

        // Entrypoint for parameterless RPCs or full builder control
        inline operator fun <reified R : Any> invoke(
            noinline block: Builder<R>.() -> Unit
        ): RpcPost<R> =
            Builder(Jackson.autoBody<R>().toLens())
                .apply(block)
                .build()
    }
}