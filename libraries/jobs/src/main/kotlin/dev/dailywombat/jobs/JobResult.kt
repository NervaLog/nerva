package dev.dailywombat.jobs

/**
 * Result of executing a job.
 */
sealed interface JobResult {
    /** Job completed successfully */
    data object Success : JobResult

    /** Job failed but should be retried */
    data class Retry(val reason: String) : JobResult

    /** Job failed permanently - don't retry */
    data class Fail(val reason: String) : JobResult
}