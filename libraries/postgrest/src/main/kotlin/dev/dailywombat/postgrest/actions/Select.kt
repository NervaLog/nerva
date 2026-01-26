@file:Suppress("MayBeConstant")

package dev.dailywombat.postgrest.actions

import dev.dailywombat.flyway.modules.ModuleSchema
import dev.dailywombat.postgrest.PostgRestAction
import dev.dailywombat.postgrest.headers.Prefer
import org.http4k.core.Method
import org.http4k.core.Request
import org.http4k.core.Uri
import kotlin.reflect.KProperty1


class Select<R : Any> private constructor(
    internal val hFilters: List<HorizontalFilter<R>>,
    internal val select: List<SelectExpr>,
    internal val accept: List<String>,
    internal val prefer: List<Prefer>,
    internal val acceptProfile: String?,
) : PostgRestAction<R> {

    /**
     * Select clause AST.
     *
     * Note: Embedding takes a *list* of sub-expressions, which matches PostgREST syntax:
     *   entity(sub1,sub2,sub3)
     */
    sealed class SelectExpr {
        data object Star : SelectExpr()

        data class Props(
            val props: List<KProperty1<*, *>>
        ) : SelectExpr() {
            constructor(vararg props: KProperty1<*, *>) : this(props.toList())
        }

        data class Embedding(
            val entity: String,
            val sub: List<SelectExpr>,
            val alias: String? = null
        ) : SelectExpr()

        fun queryValue(): String = when (this) {
            Star -> "*"
            is Props -> props.joinToString(",") { it.name }
            is Embedding -> {
                val inner = sub.joinToString(",") { it.queryValue() }
                val core = "$entity($inner)"
                if (alias.isNullOrBlank()) core else "$alias:$core"
            }
        }
    }

    // Filters (renamed slightly for clarity; keep your names if you prefer)
    sealed interface HorizontalFilter<A : Any> {
        val query: Pair<String, String>

        data class Eq<A : Any, P>(val prop: KProperty1<A, P?>, val value: P) : HorizontalFilter<A> {
            override val query = prop.name to "eq.$value"
        }

        data class Gt<A : Any, P>(val prop: KProperty1<A, P>, val value: P) : HorizontalFilter<A> {
            override val query = prop.name to "gt.$value"
        }

        data class Gte<A : Any, P>(val prop: KProperty1<A, P>, val value: P) : HorizontalFilter<A> {
            override val query = prop.name to "gte.$value"
        }

        data class Lt<A : Any, P>(val prop: KProperty1<A, P>, val value: P) : HorizontalFilter<A> {
            override val query = prop.name to "lt.$value"
        }

        data class Lte<A : Any, P>(val prop: KProperty1<A, P>, val value: P) : HorizontalFilter<A> {
            override val query = prop.name to "lte.$value"
        }

        data class Like<A : Any>(val prop: KProperty1<A, String>, val value: String) : HorizontalFilter<A> {
            override val query = prop.name to "like.$value"
        }

        data class In<A : Any, P>(val prop: KProperty1<A, P>, val values: List<P>) : HorizontalFilter<A> {
            override val query = prop.name to "in.(${values.joinToString(",")})"
        }
    }

    object Accept {
        const val SingularRepresentation = "application/vnd.pgrst.object+json"
    }

    // --- DSL ----------------------------------------------------------------------------------

    class Builder<R : Any> {
        val filters = mutableListOf<HorizontalFilter<R>>()
        private val selectExprs = mutableListOf<SelectExpr>()
        private val accept = mutableListOf<String>()
        private val prefer = mutableListOf<Prefer>()
        private var acceptProfile: String? = null

        // Filters
        fun <P> eq(prop: KProperty1<R, P>, value: P) = apply { filters += HorizontalFilter.Eq(prop, value) }
        fun <P> gt(prop: KProperty1<R, P>, value: P) = apply { filters += HorizontalFilter.Gt(prop, value) }
        fun <P> gte(prop: KProperty1<R, P>, value: P) = apply { filters += HorizontalFilter.Gte(prop, value) }
        fun <P> lt(prop: KProperty1<R, P>, value: P) = apply { filters += HorizontalFilter.Lt(prop, value) }
        fun <P> lte(prop: KProperty1<R, P>, value: P) = apply { filters += HorizontalFilter.Lte(prop, value) }
        fun like(prop: KProperty1<R, String>, value: String) = apply { filters += HorizontalFilter.Like(prop, value) }
        fun <P> `in`(prop: KProperty1<R, P>, values: List<P>) = apply { filters += HorizontalFilter.In(prop, values) }
        fun <P> `in`(prop: KProperty1<R, P>, vararg values: P) =
            apply { filters += HorizontalFilter.In(prop, values.toList()) }

        // Select clause DSL
        fun select(block: SelectDsl.() -> Unit) = apply {
            val built = SelectDsl().apply(block).build()
            selectExprs.clear()
            selectExprs += built
        }

        // Headers/options
        fun accept(vararg values: String) = apply { accept += values }
        fun prefer(vararg values: Prefer) = apply { prefer += values }
        fun acceptProfile(value: ModuleSchema) = apply { acceptProfile = value.name }

        fun build(): Select<R> = Select(
            hFilters = filters.toList(),
            select = selectExprs.toList(),
            accept = accept.toList(),
            prefer = prefer.toList(),
            acceptProfile = acceptProfile
        )
    }

    class SelectDsl {
        private val parts = mutableListOf<SelectExpr>()

        fun star() = apply { parts += SelectExpr.Star }

        fun <A : Any> props(vararg p: KProperty1<A, *>) = apply {
            @Suppress("UNCHECKED_CAST")
            parts += SelectExpr.Props(p.toList() as List<KProperty1<*, *>>)
        }

        fun embed(entity: String, alias: String? = null, block: SelectDsl.() -> Unit) = apply {
            val sub = SelectDsl().apply(block).build()
            parts += SelectExpr.Embedding(entity = entity, sub = sub, alias = alias)
        }

        internal fun build(): List<SelectExpr> =
            if (parts.isEmpty()) listOf(SelectExpr.Star) else parts.toList()
    }

    companion object {
        operator fun <R : Any> invoke(block: Builder<R>.() -> Unit): Select<R> =
            Builder<R>().apply(block).build()
    }

    // --- Request construction ------------------------------------------------------------------

    override fun toRequest(baseUri: Uri, entity: String): Request {
        var req = Request(Method.GET, "$baseUri/$entity")

        // Filters as query params
        for ((k, v) in hFilters.map { it.query }) {
            req = req.query(k, v)
        }

        // select=...
        if (select.isNotEmpty()) {
            val selectValue = select.joinToString(",") { it.queryValue() }
            req = req.query("select", selectValue)
        }

        // Headers
        if (accept.isNotEmpty()) req = req.header("Accept", accept.joinToString(", "))
        if (prefer.isNotEmpty()) req = req.header("Prefer", prefer.joinToString(", ") { it.value })
        if (!acceptProfile.isNullOrBlank()) req = req.header("Accept-Profile", acceptProfile)

        return req
    }
}
