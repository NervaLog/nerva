package dev.dailywombat.jobs.integration.support.db

import java.time.Instant
import java.util.*

/**
 * Row from jobs.jobs table for assertions.
 */
data class JobRow(
    val id: UUID,
    val jobType: String,
    val idempotencyKey: String?,
    val targetType: String,
    val targetId: UUID,
    val priority: Int,
    val params: String?,
    val createdAt: Instant?,
    val availableAt: Instant?,
    val status: String,
    val leaseOwner: String?,
    val leaseUntil: Instant?,
    val leaseCount: Int,
    val attempts: Int,
    val lastError: String?,
    val completedAt: Instant?,
    val replayedFrom: UUID?
)