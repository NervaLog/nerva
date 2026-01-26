package dev.dailywombat.postgrest.actions

import arrow.core.raise.context.Raise
import dev.dailywombat.flyway.modules.Entity
import dev.dailywombat.flyway.modules.ModuleSchema
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.headers.Prefer
import org.http4k.format.Jackson
import org.http4k.lens.BiDiBodyLens

/**
 * Fetches a potentially-absent single result from an RPC without using SingularRepresentation.
 *
 * Instead of requesting SingularRepresentation (which throws on empty results),
 * this requests a list and returns `firstOrNull()`.
 *
 * ## Usage
 *
 * ```kotlin
 * context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
 * fun getConfigOrNull(surfaceId: UUID): Config? =
 *     RpcPostSingle<Args, Config>(
 *         entity = MySchema.GetConfig,
 *         args = Args(surfaceId),
 *         contentProfile = MySchema
 *     )
 * ```
 *
 * @param A The argument type for the RPC
 * @param R The result type (single item, not list)
 */
object RpcPostSingle {

    /**
     * Call an RPC that may return zero or one result.
     *
     * @param entity The RPC entity (stored procedure)
     * @param args The arguments to pass to the RPC
     * @param contentProfile Optional schema for Content-Profile header
     * @param returning Optional Prefer.Return header value
     * @return The single result, or null if no rows returned
     */
    context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
    inline operator fun <reified A : Any, reified R : Any> invoke(
        entity: Entity,
        args: A,
        contentProfile: ModuleSchema? = null,
        returning: Prefer.Return? = null
    ): R? {
        val listLens: BiDiBodyLens<List<R>> = Jackson.autoBody<List<R>>().toLens()

        val results: List<R> = context(listLens) {
            pgRest(entity, RpcPost(args) {
                contentProfile?.let { contentProfile(it) }
                returning?.let { returning(it) }
            })
        }

        return results.firstOrNull()
    }

    /**
     * Call a parameterless RPC that may return zero or one result.
     *
     * @param entity The RPC entity (stored procedure)
     * @param contentProfile Optional schema for Content-Profile header
     * @param returning Optional Prefer.Return header value
     * @return The single result, or null if no rows returned
     */
    context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
    inline fun <reified R : Any> invokeNoArgs(
        entity: Entity,
        contentProfile: ModuleSchema? = null,
        returning: Prefer.Return? = null
    ): R? {
        val listLens: BiDiBodyLens<List<R>> = Jackson.autoBody<List<R>>().toLens()

        val results: List<R> = context(listLens) {
            pgRest(entity, RpcPost<Unit> {
                contentProfile?.let { contentProfile(it) }
                returning?.let { returning(it) }
            })
        }

        return results.firstOrNull()
    }
}
