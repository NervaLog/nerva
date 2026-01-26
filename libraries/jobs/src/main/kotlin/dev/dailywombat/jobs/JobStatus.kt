@file:Suppress("EnumEntryName")

package dev.dailywombat.jobs

/**
 * Lifecycle status of a job.
 *
 * Matches the PostgreSQL enum `jobs.job_status`.
 */
enum class JobStatus {
    /** Waiting to be picked up by a worker */
    pending,

    /** Currently leased by a worker */
    processing,

    /** Failed once, will retry after available_at */
    retrying,

    /** Successfully processed (terminal) */
    completed,

    /** Retry attempts exhausted (terminal) */
    failed,

    /** Manually marked as unprocessable (terminal) */
    dead;

    /**
     * Returns true if this is a terminal status (job will not be processed further).
     */
    fun isTerminal(): Boolean = this in TERMINAL_STATUSES

    companion object {
        private val TERMINAL_STATUSES = setOf(completed, failed, dead)

        fun fromString(value: String): JobStatus =
            entries.find { it.name == value }
                ?: throw IllegalArgumentException("Unknown job status: $value")

        fun fromStringOrNull(value: String): JobStatus? =
            entries.find { it.name == value }
    }
}
