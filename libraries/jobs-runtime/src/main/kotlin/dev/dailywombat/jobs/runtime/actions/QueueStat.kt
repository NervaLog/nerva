package dev.dailywombat.jobs.runtime.actions

import dev.dailywombat.jobs.JobStatus

/**
 * Queue statistics for a single status.
 */
data class QueueStat(
    val status: JobStatus,
    val count: Long,
    val oldestAgeSeconds: Double
)