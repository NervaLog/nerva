package dev.template.app.endpoints.api.events

import arrow.core.raise.either
import com.fasterxml.jackson.databind.JsonNode
import dev.dailywombat.postgrest.PostgRestClient
import dev.nerva.nerva.actions.IngestEvent
import dev.nerva.nerva.actions.IngestEventInput
import dev.nerva.nerva.auth.AuthenticatedOrgKey
import dev.nerva.nerva.enums.AttentionKind
import dev.nerva.nerva.enums.EventType
import org.http4k.core.Body
import org.http4k.core.Method
import org.http4k.core.Request
import org.http4k.core.Response
import org.http4k.core.Status
import org.http4k.format.Jackson
import org.http4k.format.Jackson.auto
import org.http4k.routing.RoutingHttpHandler
import org.http4k.routing.bind
import java.time.Instant
import java.util.*

object IngestEvents {

    data class IngestEventRequest(
        val provider: String,
        val external_id: String,
        val event_type: String,
        val payload: JsonNode? = null,
        val occurred_at: String? = null,
        val collapse_key: String? = null,
        val collapse_window_minutes: Int? = null,
        val attention_kind: String? = null,
        val title: String? = null,
        val body: String? = null,
        val deeplink_url: String? = null,
        val expires_at: String? = null
    )

    data class IngestEventResponse(
        val event_id: UUID,
        val attention_id: UUID?,
        val was_created: Boolean,
        val job_id: UUID?
    )

    data class ErrorResponse(
        val error: String,
        val message: String
    )

    private val requestLens = Body.auto<IngestEventRequest>().toLens()
    private val responseLens = Jackson.autoBody<IngestEventResponse>().toLens()
    private val errorLens = Jackson.autoBody<ErrorResponse>().toLens()

    context(pgRest: PostgRestClient)
    operator fun invoke(): RoutingHttpHandler =
        "/api/v1/events" bind Method.POST to { request ->
            val auth = AuthenticatedOrgKey(request)
            if (auth == null) {
                errorLens(
                    ErrorResponse("unauthorized", "Missing or invalid API key"),
                    Response(Status.UNAUTHORIZED)
                )
            } else {
                handleIngest(request, auth.orgId)
            }
        }

    context(pgRest: PostgRestClient)
    private fun handleIngest(request: Request, orgId: UUID): Response {
        val body = try {
            requestLens(request)
        } catch (e: Exception) {
            return errorLens(
                ErrorResponse("invalid_request", "Invalid request body: ${e.message}"),
                Response(Status.BAD_REQUEST)
            )
        }

        // Validate event_type
        val eventType = try {
            EventType.fromValue(body.event_type)
        } catch (e: Exception) {
            return errorLens(
                ErrorResponse("invalid_event_type", "Unknown event type: ${body.event_type}"),
                Response(Status.BAD_REQUEST)
            )
        }

        // Parse optional attention_kind
        val attentionKind = body.attention_kind?.let {
            try {
                AttentionKind.fromValue(it)
            } catch (e: Exception) {
                return errorLens(
                    ErrorResponse("invalid_attention_kind", "Unknown attention kind: $it"),
                    Response(Status.BAD_REQUEST)
                )
            }
        } ?: AttentionKind.BATCH

        val input = IngestEventInput(
            orgId = orgId,
            provider = body.provider,
            externalId = body.external_id,
            eventType = eventType,
            payload = body.payload,
            occurredAt = body.occurred_at?.let { Instant.parse(it) },
            collapseKey = body.collapse_key,
            collapseWindowMinutes = body.collapse_window_minutes ?: 5,
            attentionKind = attentionKind,
            title = body.title,
            body = body.body,
            deeplinkUrl = body.deeplink_url,
            expiresAt = body.expires_at?.let { Instant.parse(it) }
        )

        return either { IngestEvent(input) }.fold(
            ifLeft = { error ->
                errorLens(
                    ErrorResponse("ingest_failed", "Failed to ingest event: $error"),
                    Response(Status.INTERNAL_SERVER_ERROR)
                )
            },
            ifRight = { result ->
                responseLens(
                    IngestEventResponse(
                        event_id = result.eventId,
                        attention_id = result.attentionId,
                        was_created = result.wasCreated,
                        job_id = result.jobId
                    ),
                    Response(if (result.wasCreated) Status.CREATED else Status.OK)
                )
            }
        )
    }
}
