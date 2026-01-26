package dev.dailywombat.postgrest

import arrow.core.raise.context.Raise
import arrow.core.raise.context.raise
import arrow.core.raise.context.withError
import dev.dailywombat.flyway.modules.Entity
import dev.dailywombat.postgrest.PostgRestError.*
import dev.dailywombat.postgrest.actions.Select.Accept.SingularRepresentation
import org.http4k.core.HttpHandler
import org.http4k.core.Request
import org.http4k.core.Response
import org.http4k.core.Status
import org.http4k.lens.LensExtractor

@ConsistentCopyVisibility
data class PostgRestClient internal constructor(
    val config: PostgRestConfig,
    private val client: HttpHandler
) {
    /**
     * @param I input type
     * @param O output type
     * @param entity table/view/stored-proc name
     * @param action @see [dev.dailywombat.postgrest.actions.Select], etc
     * @param extractor how to get the response type out of PgRest's response
     */
    context(
        extractor: LensExtractor<Response, O>,
        _: Raise<PostgRestError>
    )
    operator fun <I : Any, O : Any> invoke(
        entity: Entity,
        action: PostgRestAction<I>
    ): O {
        val request = action.toRequest(config.baseUri, entity.name)
        val response = withError(PostgRestError::NetworkError) { client(request) }

        return when {
            response.status.successful ->
                withError(::catchLensFailure) { extractor(response) }

            request.askedForSingularRepresentation() && response.notAcceptable() ->
                raise(SingularNotFound)

            else -> {
                val details = withError(::catchLensFailure) { Details.Lens(response) }
                raise(SpecificError(response.status, body = details))
            }
        }
    }

    private fun catchLensFailure(t: Throwable): PostgRestError =
        when (t) {
            is org.http4k.lens.LensFailure -> LensFailure(t)
            else -> CriticalError(t)
        }

    private fun Request.askedForSingularRepresentation() =
        (header("Accept") ?: "").contains(SingularRepresentation)

    private fun Response.notAcceptable() =
        status == Status.NOT_ACCEPTABLE
}