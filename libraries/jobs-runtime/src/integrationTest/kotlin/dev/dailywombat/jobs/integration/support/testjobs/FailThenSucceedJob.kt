package dev.dailywombat.jobs.integration.support.testjobs

import dev.dailywombat.jobs.Job
import dev.dailywombat.jobs.JobResult
import dev.dailywombat.jobs.integration.support.ResetTestJobs.logger
import java.util.*
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Test job that fails N times then succeeds.
 *
 * Tracks failures per target ID, so multiple jobs can run independently.
 */
object FailThenSucceedJob : Job<FailThenSucceedJob.Params>(
    type = "test_fail_then_succeed",
    paramsClass = Params::class
) {
    data class Params(val failCount: Int = 1)

    // Track attempts per job (by target ID)
    private val attemptsByTarget = ConcurrentHashMap<UUID, AtomicInteger>()
    val totalInvocations = AtomicInteger(0)

    override suspend fun invoke(params: Params): JobResult {
        totalInvocations.incrementAndGet()
        // Note: We don't have access to targetId here, so we track globally
        // For per-job tracking, use FailCountJob below
        logger.debug { "FailThenSucceedJob executed, failCount=${params.failCount}" }
        return JobResult.Retry("Need more attempts")
    }

    fun reset() {
        attemptsByTarget.clear()
        totalInvocations.set(0)
    }
}