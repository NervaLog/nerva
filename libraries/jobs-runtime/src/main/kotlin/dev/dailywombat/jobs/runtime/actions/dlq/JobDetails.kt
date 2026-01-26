package dev.dailywombat.jobs.runtime.actions.dlq

import dev.dailywombat.jobs.JobStatus
import java.time.Instant
import java.util.*

/**
 * Full details of a job from inspection.
 */
data class JobDetails(
    val id: UUID,
    val jobType: String,
    val idempotencyKey: String?,
    val targetType: String,
    val targetId: UUID,
    val params: Map<String, Any>?,
    val priority: Int,
    val createdAt: Instant,
    val availableAt: Instant,
    val status: JobStatus,
    val leaseOwner: String?,
    val leaseUntil: Instant?,
    val leaseCount: Int,
    val attempts: Int,
    val lastError: String?,
    val completedAt: Instant?,
    val replayedFrom: UUID?
)