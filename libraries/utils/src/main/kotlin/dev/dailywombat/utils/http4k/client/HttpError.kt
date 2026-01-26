package dev.dailywombat.utils.http4k.client

import org.http4k.core.Response
import org.http4k.core.Status
import org.http4k.lens.LensFailure

sealed interface HttpError {
    data class NetworkError(val cause: Throwable) : HttpError
    data class LensError(val error: LensFailure) : HttpError
    data class UnsuccessfulResponse(
        val status: Status,
        val headers: Map<String, String?>,
        val body: String
    ) : HttpError {
        companion object {
            operator fun invoke(r: Response) = UnsuccessfulResponse(
                r.status, r.headers.toMap(), r.bodyString()
            )
        }
    }
}