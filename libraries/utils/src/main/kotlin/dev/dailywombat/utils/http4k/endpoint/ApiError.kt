package dev.dailywombat.utils.http4k.endpoint

import org.http4k.lens.LensFailure

sealed interface ApiError {
    data class DeSer(val error: LensFailure) : ApiError
    data class SerDe(val error: LensFailure) : ApiError
    data class DomainFailure(val error: Any) : ApiError
    data class Critical(val error: Throwable) : ApiError
}
