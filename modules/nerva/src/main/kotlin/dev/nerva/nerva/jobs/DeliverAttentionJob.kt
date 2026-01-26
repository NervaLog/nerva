package dev.nerva.nerva.jobs

import arrow.core.raise.either
import dev.dailywombat.jobs.Job
import dev.dailywombat.jobs.JobResult
import dev.dailywombat.jobs.runtime.JobContext
import dev.nerva.nerva.actions.GetAttentionById
import dev.nerva.nerva.actions.GetDeviceEndpoints
import dev.nerva.nerva.actions.RenderAttentionPayload
import dev.nerva.nerva.actions.UpdateAttentionStatus
import dev.nerva.nerva.enums.AttentionStatus
import dev.nerva.nerva.push.PushAdapter
import dev.nerva.nerva.push.StubPushAdapter
import io.github.oshai.kotlinlogging.KotlinLogging
import java.time.Instant
import java.util.*

private val logger = KotlinLogging.logger {}

object DeliverAttentionJob : Job<DeliverAttentionJob.Params>(
    type = "deliver_attention",
    paramsClass = Params::class
) {
    data class Params(
        val targetId: UUID? = null  // attention_projection.id (from target_id in job)
    )

    // Injected at app startup, defaults to stub
    var pushAdapter: PushAdapter = StubPushAdapter

    override suspend operator fun invoke(params: Params): JobResult {
        val attentionId = params.targetId
            ?: return JobResult.Fail("Missing targetId (attention_projection.id)")

        val pgRest = JobContext.current()
            ?: return JobResult.Fail("No PostgRestClient in context")

        logger.info { "Delivering attention: $attentionId" }

        // Fetch the attention item
        val attention = either {
            context(pgRest) {
                GetAttentionById(attentionId)
            }
        }.fold(
            ifLeft = { error -> return JobResult.Retry("Failed to fetch attention: $error") },
            ifRight = { it }
        )

        if (attention == null) {
            return JobResult.Fail("Attention item not found: $attentionId")
        }

        // Skip if already delivered or dismissed
        if (attention.status != AttentionStatus.PENDING) {
            logger.info { "Skipping attention $attentionId - status is ${attention.status}" }
            return JobResult.Success
        }

        // Render the push payload
        val payload = either {
            context(pgRest) {
                RenderAttentionPayload(attentionId)
            }
        }.fold(
            ifLeft = { error -> return JobResult.Retry("Failed to render payload: $error") },
            ifRight = { it }
        )

        // Get device endpoints for this org
        val devices = either {
            context(pgRest) {
                GetDeviceEndpoints(attention.org_id)
            }
        }.fold(
            ifLeft = { error -> return JobResult.Retry("Failed to fetch devices: $error") },
            ifRight = { it }
        )

        if (devices.isEmpty()) {
            logger.info { "No devices for org ${attention.org_id}, marking as delivered" }
        } else {
            // Send to all devices
            var anySuccess = false
            for (device in devices) {
                val result = pushAdapter.send(
                    deviceToken = device.device_token,
                    platform = device.platform,
                    payload = payload
                )
                result.fold(
                    ifLeft = { error ->
                        logger.warn { "Push failed for device ${device.id}: $error" }
                    },
                    ifRight = { messageId ->
                        logger.info { "Push sent to device ${device.id}: $messageId" }
                        anySuccess = true
                    }
                )
            }

            if (!anySuccess && devices.isNotEmpty()) {
                return JobResult.Retry("All push attempts failed")
            }
        }

        // Mark as delivered
        either {
            context(pgRest) {
                UpdateAttentionStatus(
                    id = attentionId,
                    status = AttentionStatus.DELIVERED,
                    deliveredAt = Instant.now()
                )
            }
        }.fold(
            ifLeft = { error ->
                logger.warn { "Failed to update attention status: $error" }
                // Don't retry - the push was sent
            },
            ifRight = { }
        )

        logger.info { "Attention $attentionId delivered to ${devices.size} device(s)" }
        return JobResult.Success
    }
}
