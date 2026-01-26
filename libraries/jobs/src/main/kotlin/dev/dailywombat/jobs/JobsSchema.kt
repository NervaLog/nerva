@file:Suppress("HasPlatformType")

package dev.dailywombat.jobs

import dev.dailywombat.flyway.modules.Entity.Companion.enum
import dev.dailywombat.flyway.modules.Entity.Companion.errorCode
import dev.dailywombat.flyway.modules.Entity.Companion.storedFunc
import dev.dailywombat.flyway.modules.Entity.Companion.table
import dev.dailywombat.flyway.modules.ModuleSchema

/**
 * Jobs module schema definition.
 *
 * The jobs schema provides a background job queue for async processing.
 * Unlike the events schema (for external events), this is for internal
 * work like running the planner and executor.
 *
 * Architecture:
 *   External Event (Stripe) → Ledger Journal (fact) → Job Queue → Planner → Executor
 */
object JobsSchema : ModuleSchema() {
    override val name = "jobs"

    // =========================================================================
    // Enums
    // =========================================================================

    /** Lifecycle status of a job */
    val JobStatus = enum("job_status")

    // =========================================================================
    // Tables
    // =========================================================================

    /** Main job queue table */
    val Jobs = table("jobs")

    /** Dead letter queue for failed jobs */
    val JobsDeadLetter = table("jobs_dead_letter")

    // =========================================================================
    // Stored Functions
    // =========================================================================

    /** Enqueue a job with idempotency support */
    val EnqueueJob = storedFunc("enqueue_job")

    /** Lease jobs for processing */
    val LeaseJobs = storedFunc("lease_jobs")

    /** Mark a job as completed */
    val CompleteJob = storedFunc("complete_job")

    /** Fail or retry a job with backoff */
    val FailOrRetryJob = storedFunc("fail_or_retry_job")

    /** Release jobs with expired leases */
    val ReleaseStaleJobs = storedFunc("release_stale_jobs")

    /** List failed jobs with filters (DLQ) */
    val ListFailedJobs = storedFunc("list_failed_jobs")

    /** Get full job details (DLQ) */
    val InspectJob = storedFunc("inspect_job")

    /** Replay a failed job (DLQ) */
    val ReplayJob = storedFunc("replay_job")

    /** Get queue statistics for metrics (Metrics) */
    val QueueStats = storedFunc("queue_stats")

    // =========================================================================
    // Error Codes
    // =========================================================================

    /** Job not found or not owned by this worker */
    val JobNotFound = errorCode("JB001", description = "Job not found or not owned by worker")

    /** Job not found (for replay) */
    val JobNotFoundForReplay = errorCode("JB002", description = "Job not found")

    /** Job is not in failed status (for replay) */
    val JobNotFailed = errorCode("JB003", description = "Job is not in failed status")

    // =========================================================================
    // Channels
    // =========================================================================

    /** LISTEN/NOTIFY channel for job queue wake-ups */
    const val JOB_NOTIFICATIONS_CHANNEL = "job_notifications"
}
