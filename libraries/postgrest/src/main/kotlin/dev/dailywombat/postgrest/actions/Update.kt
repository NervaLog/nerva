package dev.dailywombat.postgrest.actions

import dev.dailywombat.flyway.modules.ModuleSchema
import dev.dailywombat.postgrest.PostgRestAction
import dev.dailywombat.postgrest.headers.Prefer
import org.http4k.core.Method.PATCH
import org.http4k.core.Request
import org.http4k.core.Uri
import org.http4k.format.Jackson
import org.http4k.lens.BiDiBodyLens
import org.http4k.lens.LensInjector
import kotlin.reflect.KProperty1

class Update<R : Any> private constructor(
    internal val values: Map<String, Any?>,
    internal val filters: List<Select.HorizontalFilter<R>>,
    internal val injector: LensInjector<Map<String, Any?>, Request>,
    internal val accept: List<String>,
    internal val contentProfile: String?,
    internal val returning: Prefer.Return
) : PostgRestAction<R> {

    class SetDsl<R : Any> {
        internal val values = mutableMapOf<String, Any?>()

        infix fun <P> KProperty1<R, P?>.set(value: P?) {
            values[this.name] = value
        }
    }


    override fun toRequest(baseUri: Uri, entity: String): Request {
        var req = Request(PATCH, Uri.of("$baseUri/$entity"))

        // filters
        for ((k, v) in filters.map { it.query }) {
            req = req.query(k, v)
        }

        // body
        req = injector(values, req)

        // headers
        req = req.header("Prefer", returning.value)
        if (accept.isNotEmpty()) req = req.header("Accept", accept.joinToString(", "))
        if (!contentProfile.isNullOrBlank()) req = req.header("Content-Profile", contentProfile)

        return req
    }

    class Builder<R : Any>(
        private val defaultBody: BiDiBodyLens<Map<String, Any?>>
    ) {
        private val filters = mutableListOf<Select.HorizontalFilter<R>>()
        private val values = mutableMapOf<String, Any?>()

        private var injector: LensInjector<Map<String, Any?>, Request>? = null
        private val accept = mutableListOf<String>()
        private var contentProfile: String? = null
        private var returning: Prefer.Return = Prefer.Return.Minimal

        fun set(block: SetDsl<R>.() -> Unit) = apply {
            values += SetDsl<R>().apply(block).values
        }

        fun where(block: Select.Builder<R>.() -> Unit) = apply {
            filters += Select.Builder<R>().apply(block).build().hFilters
        }

        fun accept(vararg v: String) = apply { accept += v }
        fun contentProfile(value: ModuleSchema) = apply { contentProfile = value.name }
        fun returning(v: Prefer.Return) = apply { returning = v }

        fun build(): Update<R> {
            require(values.isNotEmpty()) { "Update requires at least one set(...)" }
            require(filters.isNotEmpty()) { "Update without where() is forbidden" }

            return Update(
                values = values.toMap(),
                filters = filters.toList(),
                injector = injector ?: defaultBody,
                accept = accept.toList(),
                contentProfile = contentProfile,
                returning = returning
            )
        }
    }

    companion object {
        inline operator fun <reified R : Any> invoke(
            noinline block: Builder<R>.() -> Unit
        ): Update<R> =
            Builder<R>(Jackson.autoBody<Map<String, Any?>>().toLens())
                .apply(block)
                .build()
    }
}
