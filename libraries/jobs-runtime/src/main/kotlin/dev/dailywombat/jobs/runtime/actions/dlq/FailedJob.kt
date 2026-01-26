package dev.dailywombat.jobs.runtime.actions.dlq

import java.time.Instant
import java.util.*

/**
 * A failed job from the DLQ listing.
 */
data class FailedJob(
    val id: UUID,
    val jobType: String,
    val targetType: String,
    val targetId: UUID,
    val createdAt: Instant,
    val completedAt: Instant?,
    val attempts: Int,
    val leaseCount: Int,
    val lastError: String?,
    val replayedFrom: UUID?
)