@file:Suppress("FunctionName")

package dev.dailywombat.utils.http4k

import dev.dailywombat.utils.http4k.Webhooks.InternalError
import dev.dailywombat.utils.http4k.Webhooks.InvalidFormat
import dev.dailywombat.utils.http4k.Webhooks.XWebhookStatus
import io.github.oshai.kotlinlogging.KLogger
import org.http4k.core.Filter
import org.http4k.core.Response
import org.http4k.core.Status
import org.http4k.lens.LensFailure

object BoundaryExceptionFilter {

    context(logger: KLogger)
    fun Regular(): Filter =
        buildFilter(
            onLensFailure = { logger.warn(it) {}; Response(Status.BAD_REQUEST) },
            onException = { logger.error(it) {}; Response(Status.INTERNAL_SERVER_ERROR) })

    context(logger: KLogger)
    fun Webhook() =
        buildFilter(
            onLensFailure = { logger.warn(it) {}; Response(Status.OK).header(XWebhookStatus, InvalidFormat) },
            onException = { logger.error(it) {}; Response(Status.OK).header(XWebhookStatus, InternalError) })

    /**
     * The next-to-outermost filter that should go around an http4k app AFTER structured logging.
     * The explicit handlers are due to the difference between webhooks and other HTTP endpoints.
     * Webhooks should never return an error because otherwise the source retries and
     * it becomes a stampede.
     *
     * @param onLensFailure what do if the request is bad.
     */
    private fun buildFilter(
        onLensFailure: (LensFailure) -> Response,
        onException: (Throwable) -> Response,
    ) = Filter { next ->
        { request ->
            try {
                next(request)
            } catch (e: LensFailure) {
                onLensFailure(e)
            } catch (e: Exception) {
                onException(e)
            }
        }
    }

}