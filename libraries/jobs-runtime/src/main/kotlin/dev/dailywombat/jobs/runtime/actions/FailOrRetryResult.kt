package dev.dailywombat.jobs.runtime.actions

/**
 * Result of a fail/retry operation.
 */
enum class FailOrRetryResult {
    /** Job will be retried after backoff delay */
    RETRYING,

    /** Job has exhausted retries and is now failed */
    FAILED,

    /** Job was not found or not owned by this worker */
    NOT_FOUND
}