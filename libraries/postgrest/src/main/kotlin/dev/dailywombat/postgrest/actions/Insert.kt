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

class Insert<R : Any> private constructor(
    private val entry: R,
    private val injector: LensInjector<R, Request>,
    private val accept: List<String>,
    private val contentProfile: String?,
    private val `return`: Prefer.Return,
    private val resolution: Prefer.Resolution?,
    private val onConflict: List<String>
) : PostgRestAction<R> {

    override fun toRequest(baseUri: Uri, entity: String): Request {
        var req = Request(Method.POST, Uri.of("$baseUri/$entity"))
        req = injector(entry, req)
        if (onConflict.isNotEmpty()) {
            req = req.query("on_conflict", onConflict.joinToString(","))
        }

        val prefer = buildList {
            add(`return`.value)
            resolution?.let { add(it.value) }
        }.joinToString(", ")

        req = req.header("Prefer", prefer)
        if (accept.isNotEmpty()) req = req.header(
            "Accept",
            accept.joinToString(", ")
        )
        if (!contentProfile.isNullOrBlank()) req = req.header(
            "Content-Profile",
            contentProfile
        )

        return req
    }

    class Builder<R : Any>(
        private val defaultBody: BiDiBodyLens<R>
    ) {
        private var entry: R? = null
        private var injector: LensInjector<R, Request>? = null
        private val accept = mutableListOf<String>()
        private var contentProfile: String? = null
        private var returning: Prefer.Return = Prefer.Return.Representation
        private var resolution: Prefer.Resolution? = null
        private val onConflict = mutableListOf<String>()

        fun entry(value: R) = apply { entry = value }
        fun injector(value: LensInjector<R, Request>) = apply { injector = value }
        fun body(lens: BiDiBodyLens<R>) = apply { injector = lens }

        fun accept(vararg values: String) = apply { accept += values }
        fun contentProfile(value: ModuleSchema) = apply { contentProfile = value.name }
        fun returning(value: Prefer.Return) = apply { returning = value }
        fun resolution(value: Prefer.Resolution?) = apply { resolution = value }

        /**
         * Specifies the columns to use for conflict detection with resolution=ignore-duplicates.
         * Maps to PostgREST's ?on_conflict=col1,col2 query parameter.
         */
        fun onConflict(vararg columns: String) = apply { onConflict += columns }

        fun build(): Insert<R> {
            val e = requireNotNull(entry) { "Insert requires entry(...)" }
            val inj = injector ?: defaultBody
            return Insert(
                entry = e,
                injector = inj,
                accept = accept.toList(),
                contentProfile = contentProfile,
                `return` = returning,
                resolution = resolution,
                onConflict = onConflict.toList()
            )
        }
    }

    companion object {
        // ✅ Reified entrypoint creates the default lens
        inline operator fun <reified R : Any> invoke(
            entry: R,
            noinline block: Builder<R>.() -> Unit = {}
        ): Insert<R> =
            Builder(Jackson.autoBody<R>().toLens())
                .apply { entry(entry) }
                .apply(block)
                .build()

        // ✅ Also allow Insert<R> { entry(...) ... } if you want
        inline operator fun <reified R : Any> invoke(
            noinline block: Builder<R>.() -> Unit
        ): Insert<R> =
            Builder(Jackson.autoBody<R>().toLens())
                .apply(block)
                .build()
    }
}
