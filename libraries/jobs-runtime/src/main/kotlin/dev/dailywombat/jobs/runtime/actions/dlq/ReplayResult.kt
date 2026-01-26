package dev.dailywombat.jobs.runtime.actions.dlq

import java.util.*

/**
 * Result of replaying a job.
 */
sealed interface ReplayResult {
    /** New job created successfully */
    data class Success(val newJobId: UUID) : ReplayResult

    /** Original job not found */
    data object NotFound : ReplayResult

    /** Job exists but is not in failed status */
    data object NotFailed : ReplayResult
}