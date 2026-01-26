package dev.dailywombat.jobs.integration.support.testjobs

import dev.dailywombat.jobs.Job
import dev.dailywombat.jobs.JobResult
import dev.dailywombat.jobs.integration.support.ResetTestJobs
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Test job that fails until a specific attempt count, then succeeds.
 *
 * Tracks invocations per target ID, allowing multiple jobs to work independently.
 *
 * Usage:
 * ```kotlin
 * val jobId = enqueueJob(
 *     jobType = FailUntilAttemptJob.type,
 *     targetId = myTargetId,
 *     params = mapOf("succeedOnAttempt" to 3)  // Succeed on 3rd attempt
 * )
 * ```
 */
object FailUntilAttemptJob : Job<FailUntilAttemptJob.Params>(
    type = "test_fail_until_attempt",
    paramsClass = Params::class
) {
    data class Params(
        val succeedOnAttempt: Int = 2,  // Succeed on this attempt number (1-indexed)
        val targetId: String? = null     // Optional: track by target ID from params
    )

    // Track invocation count per target ID
    private val invocationsByTarget = ConcurrentHashMap<String, AtomicInteger>()
    val totalInvocations = AtomicInteger(0)
    val successCount = AtomicInteger(0)
    val failureCount = AtomicInteger(0)

    override suspend fun invoke(params: Params): JobResult {
        totalInvocations.incrementAndGet()

        // Use targetId from params if available, otherwise use a default key
        val key = params.targetId ?: "default"
        val invocationCount = invocationsByTarget
            .computeIfAbsent(key) { AtomicInteger(0) }
            .incrementAndGet()

        ResetTestJobs.logger.debug {
            "FailUntilAttemptJob: key=$key, invocation=$invocationCount, succeedOn=${params.succeedOnAttempt}"
        }

        return if (invocationCount >= params.succeedOnAttempt) {
            successCount.incrementAndGet()
            ResetTestJobs.logger.debug { "FailUntilAttemptJob: SUCCESS on attempt $invocationCount" }
            JobResult.Success
        } else {
            failureCount.incrementAndGet()
            ResetTestJobs.logger.debug { "FailUntilAttemptJob: RETRY on attempt $invocationCount" }
            JobResult.Retry("Attempt $invocationCount < ${params.succeedOnAttempt}")
        }
    }

    /**
     * Get the invocation count for a specific target.
     */
    fun getInvocations(targetId: String): Int {
        return invocationsByTarget[targetId]?.get() ?: 0
    }

    /**
     * Get the invocation count for the default key.
     */
    fun getInvocations(): Int = getInvocations("default")

    fun reset() {
        invocationsByTarget.clear()
        totalInvocations.set(0)
        successCount.set(0)
        failureCount.set(0)
    }
}
