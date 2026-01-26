package dev.dailywombat.utils.http4k

import com.fasterxml.jackson.annotation.JsonInclude
import org.http4k.core.Body
import org.http4k.core.Response
import org.http4k.core.Status
import org.http4k.core.with
import org.http4k.format.Jackson.auto

/**
 * Standardized response DTO for webhook endpoints.
 *
 * Ensures proper JSON serialization with consistent field naming.
 * Null fields are excluded from the output.
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
data class WebhookResponse(
    val status: WebhookStatus? = null,
    val reason: String? = null,
    val error: String? = null,
    val type: String? = null,
    val journalId: String? = null
) {
    companion object {
        val lens = Body.auto<WebhookResponse>().toLens()

        fun processed() = WebhookResponse(status = WebhookStatus.processed)
        fun recorded(journalId: String) = WebhookResponse(status = WebhookStatus.recorded, journalId = journalId)
        fun duplicate() = WebhookResponse(status = WebhookStatus.duplicate)
        fun ignored(reason: String) = WebhookResponse(status = WebhookStatus.ignored, reason = reason)
        fun error(error: String, type: String? = null) = WebhookResponse(error = error, type = type)
    }
}

/**
 * Standardized error response DTO for API endpoints.
 *
 * Null fields are excluded from the output.
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
data class ErrorResponse(
    val error: String,
    val message: String? = null
) {
    companion object {
        val lens = Body.auto<ErrorResponse>().toLens()
    }
}

/**
 * Extension functions for building webhook responses with proper JSON serialization.
 */
fun Response.withWebhook(response: WebhookResponse): Response =
    with(WebhookResponse.lens of response)

fun Response.withError(response: ErrorResponse): Response =
    with(ErrorResponse.lens of response)

fun webhookProcessed(): Response =
    Response(Status.OK).withWebhook(WebhookResponse.processed())

fun webhookRecorded(journalId: String): Response =
    Response(Status.OK).withWebhook(WebhookResponse.recorded(journalId))

fun webhookDuplicate(): Response =
    Response(Status.OK).withWebhook(WebhookResponse.duplicate())

fun webhookIgnored(reason: String): Response =
    Response(Status.OK).withWebhook(WebhookResponse.ignored(reason))

fun webhookError(status: Status, error: String, type: String? = null): Response =
    Response(status).withWebhook(WebhookResponse.error(error, type))

fun errorResponse(status: Status, error: String, message: String? = null): Response =
    Response(status).withError(ErrorResponse(error, message))
