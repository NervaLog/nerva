package dev.dailywombat.jobs.runtime.actions

import java.util.*

/**
 * A job that has been leased for processing.
 *
 * @property attempts Number of actual execution failures (not stale leases)
 * @property leaseCount Number of times this job has been leased (including this one)
 */
data class LeasedJob(
    val id: UUID,
    val jobType: String,
    val targetType: String,
    val targetId: UUID,
    val params: Map<String, Any>?,
    val priority: Int,
    val attempts: Int,
    val leaseCount: Int
)