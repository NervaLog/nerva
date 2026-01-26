package dev.dailywombat.jobs.integration.support

import dev.dailywombat.jobs.integration.support.Await.condition
import dev.dailywombat.jobs.integration.support.db.JobsDb
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeout
import java.util.*
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * Polling helpers for integration test assertions.
 */
object Await {

    /**
     * Wait for a condition to become true.
     *
     * @param timeout Maximum time to wait
     * @param interval Polling interval
     * @param description Description for timeout error message
     * @param condition The condition to check
     * @throws kotlinx.coroutines.TimeoutCancellationException if timeout expires
     */
    suspend fun condition(
        timeout: Duration = 5.seconds,
        interval: Duration = 50.milliseconds,
        description: String = "condition",
        condition: suspend () -> Boolean
    ) {
        withTimeout(timeout) {
            while (!condition()) {
                delay(interval)
            }
        }
    }

    /**
     * Wait for a job to reach a specific status.
     */
    suspend fun jobStatus(
        jobId: UUID,
        expected: String,
        timeout: Duration = 5.seconds
    ) {
        condition(
            timeout = timeout,
            description = "job $jobId to reach status '$expected'"
        ) {
            JobsDb.withConnection { conn ->
                JobsDb.fetchJob(conn, jobId)?.status == expected
            }
        }
    }

    /**
     * Wait for a job to reach any of the specified statuses.
     */
    suspend fun jobStatusIn(
        jobId: UUID,
        expected: Set<String>,
        timeout: Duration = 5.seconds
    ) {
        condition(
            timeout = timeout,
            description = "job $jobId to reach status in $expected"
        ) {
            JobsDb.withConnection { conn ->
                JobsDb.fetchJob(conn, jobId)?.status in expected
            }
        }
    }

    /**
     * Wait for the queue to be fully drained.
     *
     * Asserts:
     * - No jobs in 'pending' status
     * - No jobs in 'retrying' status
     * - No jobs in 'processing' status (or all processing jobs have valid leases)
     */
    suspend fun queueDrained(timeout: Duration = 10.seconds) {
        condition(
            timeout = timeout,
            description = "queue to be drained"
        ) {
            JobsDb.withConnection { conn ->
                val counts = JobsDb.countByStatus(conn)
                val pending = counts["pending"] ?: 0
                val retrying = counts["retrying"] ?: 0
                val processing = counts["processing"] ?: 0

                pending == 0 && retrying == 0 && processing == 0
            }
        }
    }

    /**
     * Wait for all jobs to reach a terminal state (completed, failed, or dead).
     */
    suspend fun allJobsTerminal(timeout: Duration = 10.seconds) {
        condition(
            timeout = timeout,
            description = "all jobs to reach terminal state"
        ) {
            JobsDb.withConnection { conn ->
                val counts = JobsDb.countByStatus(conn)
                val nonTerminal = (counts["pending"] ?: 0) +
                        (counts["retrying"] ?: 0) +
                        (counts["processing"] ?: 0)

                nonTerminal == 0
            }
        }
    }

    /**
     * Wait for a specific number of jobs with a given status.
     */
    suspend fun jobCount(
        status: String,
        expected: Int,
        timeout: Duration = 5.seconds
    ) {
        condition(
            timeout = timeout,
            description = "$expected jobs with status '$status'"
        ) {
            JobsDb.withConnection { conn ->
                val counts = JobsDb.countByStatus(conn)
                (counts[status] ?: 0) == expected
            }
        }
    }

    /**
     * Wait for at least N jobs with a given status.
     */
    suspend fun atLeastJobCount(
        status: String,
        minimum: Int,
        timeout: Duration = 5.seconds
    ) {
        condition(
            timeout = timeout,
            description = "at least $minimum jobs with status '$status'"
        ) {
            JobsDb.withConnection { conn ->
                val counts = JobsDb.countByStatus(conn)
                (counts[status] ?: 0) >= minimum
            }
        }
    }

    /**
     * Wait for a job's attempts to reach a specific value.
     */
    suspend fun jobAttempts(
        jobId: UUID,
        expected: Int,
        timeout: Duration = 5.seconds
    ) {
        condition(
            timeout = timeout,
            description = "job $jobId to have $expected attempts"
        ) {
            JobsDb.withConnection { conn ->
                JobsDb.fetchJob(conn, jobId)?.attempts == expected
            }
        }
    }
}
