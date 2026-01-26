package dev.nerva.nerva.push

import arrow.core.Either
import com.fasterxml.jackson.databind.JsonNode
import java.util.*

sealed class PushError {
    data class InvalidToken(val token: String) : PushError()
    data class RateLimited(val retryAfter: Long?) : PushError()
    data class ServiceUnavailable(val message: String) : PushError()
    data class Unknown(val message: String) : PushError()
}

data class PushResult(
    val deviceId: UUID,
    val success: Boolean,
    val messageId: String? = null,
    val error: PushError? = null
)

interface PushAdapter {
    suspend fun send(
        deviceToken: String,
        platform: String,
        payload: JsonNode
    ): Either<PushError, String>
}
