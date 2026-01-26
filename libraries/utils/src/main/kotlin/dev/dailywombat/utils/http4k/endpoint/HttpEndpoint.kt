package dev.dailywombat.utils.http4k.endpoint

import arrow.core.raise.context.Raise
import arrow.core.raise.context.raise
import arrow.core.raise.context.withError
import arrow.core.raise.recover
import dev.dailywombat.utils.http4k.endpoint.ApiError.DomainFailure
import io.github.oshai.kotlinlogging.KLogger
import org.http4k.core.HttpHandler
import org.http4k.core.Request
import org.http4k.core.Response
import org.http4k.core.Status
import org.http4k.core.Status.Companion.BAD_REQUEST
import org.http4k.core.Status.Companion.INTERNAL_SERVER_ERROR
import org.http4k.core.Status.Companion.OK
import org.http4k.format.Jackson
import org.http4k.lens.LensExtractor
import org.http4k.lens.LensFailure
import org.http4k.lens.LensInjector

object HttpEndpoint {

    context(
        logger: KLogger,
    )
    operator fun <A : Any, R : Any, E : Any> invoke(
        lensEx: LensExtractor<Request, A>,
        lensInj: LensInjector<R, Response>,
        work: context(Raise<E>) (A) -> R,
        onDomainError: (DomainFailure) -> Response = { it.onFailure() },
    ): HttpHandler = { req ->
        recover(
            block = {
                val input = req.deserializeRequest(lensEx)
                val result = withError({ e: E -> DomainFailure(e as Any) }) { work(input) }
                result.toResponse(lensInj)
            },
            recover = { err ->
                when (err) {
                    is ApiError.DeSer -> {
                        logger.atWarn {
                            message = "failure reading request"
                            cause = err.error
                        }
                        Response(BAD_REQUEST)
                    }

                    is ApiError.SerDe -> {
                        logger.atError {
                            message = "failure writing response"
                            cause = err.error
                        }
                        Response(INTERNAL_SERVER_ERROR)
                    }

                    is DomainFailure -> onDomainError(err)

                    is ApiError.Critical -> {
                        logger.atError {
                            message = "critical error in endpoint"
                            cause = err.error
                        }
                        Response(INTERNAL_SERVER_ERROR)
                    }
                }
            })
    }

    context(logger: KLogger)
    fun DomainFailure.onFailure(): Response {
        logger.atError {
            message = Jackson.asFormatString(this@onFailure)
        }
        return Response(INTERNAL_SERVER_ERROR)
    }

    context(_: Raise<ApiError>)
    private fun <A> Request.deserializeRequest(lens: LensExtractor<Request, A>): A =
        try {
            lens(this)
        } catch (e: LensFailure) {
            raise(ApiError.DeSer(e))
        } catch (t: Throwable) {
            raise(ApiError.Critical(t))
        }

    context(_: Raise<ApiError>)
    private fun <R : Any> R.toResponse(
        injector: LensInjector<R, Response>,
        status: Status = OK
    ): Response =
        try {
            injector.inject(this, Response(status))
        } catch (e: LensFailure) {
            raise(ApiError.SerDe(e))
        } catch (t: Throwable) {
            raise(ApiError.Critical(t))
        }
}