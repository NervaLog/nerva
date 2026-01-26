package dev.nerva.nerva.push

import arrow.core.Either
import arrow.core.right
import com.fasterxml.jackson.databind.JsonNode
import io.github.oshai.kotlinlogging.KotlinLogging
import java.util.*

private val logger = KotlinLogging.logger {}

object StubPushAdapter : PushAdapter {

    override suspend fun send(
        deviceToken: String,
        platform: String,
        payload: JsonNode
    ): Either<PushError, String> {
        val messageId = "stub_${UUID.randomUUID()}"
        logger.info {
            "STUB PUSH: platform=$platform, token=${deviceToken.take(8)}..., " +
            "payload=${payload.toString().take(100)}, messageId=$messageId"
        }
        return messageId.right()
    }
}
