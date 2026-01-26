package dev.dailywombat.jobs.runtime.processor

import arrow.core.raise.Raise
import arrow.core.raise.either
import com.fasterxml.jackson.databind.ObjectMapper
import dev.dailywombat.jobs.Job
import dev.dailywombat.jobs.JobResult
import dev.dailywombat.jobs.runtime.JobMetrics
import dev.dailywombat.jobs.runtime.JobRegistry
import dev.dailywombat.jobs.runtime.actions.CompleteJob
import dev.dailywombat.jobs.runtime.actions.FailOrRetryJob
import dev.dailywombat.jobs.runtime.actions.FailOrRetryResult
import dev.dailywombat.jobs.runtime.actions.LeasedJob
import dev.dailywombat.jobs.runtime.withJobContext
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import io.github.oshai.kotlinlogging.KotlinLogging

private val logger = KotlinLogging.logger {}

/**
 * Executes individual jobs with error handling and metrics.
 */
class JobExecutor(
    private val registry: JobRegistry,
    private val mapper: ObjectMapper,
    private val workerId: String,
    private val maxAttempts: Int,
    private val backoffSeconds: Int
) {

    /**
     * Execute a job with error isolation.
     *
     * Catches PostgRestErrors so infrastructure failures don't abort sibling jobs.
     * If status update fails, the job will be recovered by stale lease recovery.
     */
    suspend fun executeSafely(leased: LeasedJob, pgRest: PostgRestClient) {
        context(pgRest) {
            either<PostgRestError, Unit> {
                execute(leased)
            }.onLeft { error ->
                logger.error { "Infrastructure error processing job ${leased.id}: $error (will be recovered by stale lease recovery)" }
            }
        }
    }

    context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
    suspend fun execute(leased: LeasedJob) {
        val jobType = leased.jobType
        val handler = registry[jobType]

        if (handler == null) {
            handleUnknownJobType(leased)
            return
        }

        logger.debug { "Processing job ${leased.id} (type=$jobType, failures=${leased.attempts}, leases=${leased.leaseCount})" }

        val result = executeWithTiming(leased, handler)
        handleResult(leased, result)
    }

    context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
    private suspend fun executeWithTiming(
        leased: LeasedJob,
        handler: Job<*>
    ): JobResult {
        val startTime = System.nanoTime()
        val result = try {
            withJobContext(pgRest) {
                handler.parseAndInvoke(leased.params, mapper).invoke()
            }
        } catch (e: Exception) {
            logger.error(e) { "Exception processing job ${leased.id}" }
            JobResult.Retry(e.message ?: "Unknown error")
        }
        val durationNanos = System.nanoTime() - startTime
        JobMetrics.processingDuration(leased.jobType).record(java.time.Duration.ofNanos(durationNanos))
        return result
    }

    context(_: PostgRestClient, _: Raise<PostgRestError>)
    private fun handleUnknownJobType(leased: LeasedJob) {
        logger.warn { "No handler for job type ${leased.jobType}, failing job ${leased.id}" }
        FailOrRetryJob(
            jobId = leased.id,
            workerId = workerId,
            maxAttempts = 1,
            error = "Unknown job type: ${leased.jobType}"
        )
        JobMetrics.failed(leased.jobType).increment()
    }

    context(_: PostgRestClient, _: Raise<PostgRestError>)
    private fun handleResult(leased: LeasedJob, result: JobResult) {
        when (result) {
            is JobResult.Success -> {
                CompleteJob(leased.id, workerId)
                logger.debug { "Completed job ${leased.id}" }
                JobMetrics.completed(leased.jobType).increment()
            }
            is JobResult.Retry -> handleRetry(leased, result.reason)
            is JobResult.Fail -> handleFail(leased, result.reason)
        }
    }

    context(_: PostgRestClient, _: Raise<PostgRestError>)
    private fun handleRetry(leased: LeasedJob, reason: String) {
        val newStatus = FailOrRetryJob(
            jobId = leased.id,
            workerId = workerId,
            maxAttempts = maxAttempts,
            backoffSeconds = backoffSeconds,
            error = reason
        )
        logger.debug { "Job ${leased.id} retry result: $newStatus (reason: $reason)" }
        when (newStatus) {
            FailOrRetryResult.RETRYING -> JobMetrics.retried(leased.jobType).increment()
            FailOrRetryResult.FAILED -> JobMetrics.failed(leased.jobType).increment()
            FailOrRetryResult.NOT_FOUND -> {}
        }
    }

    context(_: PostgRestClient, _: Raise<PostgRestError>)
    private fun handleFail(leased: LeasedJob, reason: String) {
        FailOrRetryJob(
            jobId = leased.id,
            workerId = workerId,
            maxAttempts = 1,
            error = reason
        )
        logger.warn { "Job ${leased.id} permanently failed: $reason" }
        JobMetrics.failed(leased.jobType).increment()
    }
}
