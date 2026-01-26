package dev.dailywombat.postgrest

import org.http4k.core.Status
import org.http4k.format.Jackson

sealed interface PostgRestError {
    data class NetworkError(val t: Throwable) : PostgRestError
    data class LensFailure(val t: org.http4k.lens.LensFailure) : PostgRestError
    data class CriticalError(val t: Throwable) : PostgRestError
    data class SpecificError(val status: Status, val body: Details) : PostgRestError
    data object SingularNotFound : PostgRestError

    data class Details(
        val code: String,
        val message: String,
        val details: String?,
        val hint: String?
    ) {
        companion object {
            val Lens = Jackson.autoBody<Details>().toLens()
        }
    }
}