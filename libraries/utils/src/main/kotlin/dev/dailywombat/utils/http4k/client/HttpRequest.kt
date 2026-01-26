package dev.dailywombat.utils.http4k.client

import arrow.core.raise.Raise
import arrow.core.raise.catch
import arrow.core.raise.context.ensure
import arrow.core.raise.context.raise
import dev.dailywombat.utils.http4k.client.HttpError.LensError
import org.http4k.core.HttpHandler
import org.http4k.core.Request
import org.http4k.core.Response
import org.http4k.core.with
import org.http4k.lens.LensExtractor
import org.http4k.lens.LensFailure
import org.http4k.lens.LensInjector

object HttpRequest {

    // TODO: consider specialized calls for arg-less Gets etc so poor users don't have to re-invent args=Unit and so on.

    /**
     * Executes an HTTP request with typed request/response bodies using lenses.
     *
     * @param request The base HTTP request to execute
     * @param args request data to be lens-injected using lensEnj.
     * Exact placement in request (query vs path vs body) is determined by lensInj.
     *
     * @return The response, extracted with lensEx.
     *
     * @throws HttpError.LensError if request/response body encoding/decoding fails
     * @throws HttpError.NetworkError if the HTTP request execution fails
     * @throws HttpError.UnsuccessfulResponse if the response status indicates failure
     */
    context(
        handler: HttpHandler,
        _: Raise<HttpError>
    )
    operator fun <Req, Res> invoke(
        request: Request,
        args: Req,
        lensInj: LensInjector<Req, Request>,
        lensEx: LensExtractor<Response, Res>,
    ): Res {
        val buildRequest = { request.with(lensInj of args) }
        val request = catch(buildRequest) { e: LensFailure -> raise(LensError(e)) }

        val runRequest = { handler(request) }
        val response = catch(runRequest) { raise(HttpError.NetworkError(it)) }

        ensure(response.status.successful) {
            raise(HttpError.UnsuccessfulResponse(response))
        }

        val extractResponse = { lensEx(response) }
        return catch(extractResponse) { e: LensFailure -> raise(LensError(e)) }
    }
}