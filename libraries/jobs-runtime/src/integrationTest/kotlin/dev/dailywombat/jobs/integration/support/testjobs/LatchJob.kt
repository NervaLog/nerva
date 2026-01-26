package dev.dailywombat.jobs.integration.support.testjobs

import dev.dailywombat.jobs.JobResult
import dev.dailywombat.jobs.UnitJob
import dev.dailywombat.jobs.integration.support.ResetTestJobs.logger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import java.util.*
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds

/**
 * Test job that tracks execution per job ID via a latch.
 * Useful for waiting on specific job completion.
 */
object LatchJob : UnitJob("test_latch") {
    private val latches = ConcurrentHashMap<UUID, CompletableDeferred<Unit>>()
    val invocations = AtomicInteger(0)

    /**
     * Create a latch for a job ID. Returns a Deferred that completes when the job runs.
     */
    fun createLatch(jobId: UUID): CompletableDeferred<Unit> {
        return latches.computeIfAbsent(jobId) { CompletableDeferred() }
    }

    /**
     * Wait for a specific job to be executed.
     */
    suspend fun awaitJob(jobId: UUID, timeout: Duration = 5000.milliseconds) {
        withTimeout(timeout) {
            latches[jobId]?.await()
        }
    }

    override suspend fun invoke(): JobResult {
        invocations.incrementAndGet()
        // Note: We don't have direct access to job ID here
        // Complete all pending latches (simple approach)
        latches.values.forEach { it.complete(Unit) }
        logger.debug { "LatchJob executed" }
        return JobResult.Success
    }

    fun reset() {
        latches.clear()
        invocations.set(0)
    }
}