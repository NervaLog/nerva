package dev.dailywombat.jobs.integration.support.testjobs

import dev.dailywombat.jobs.JobResult
import dev.dailywombat.jobs.UnitJob
import dev.dailywombat.jobs.integration.support.ResetTestJobs.logger
import java.util.concurrent.atomic.AtomicInteger

/**
 * Test job that always fails with retry.
 */
object AlwaysRetryJob : UnitJob("test_always_retry") {
    val invocations = AtomicInteger(0)

    override suspend fun invoke(): JobResult {
        val count = invocations.incrementAndGet()
        logger.debug { "AlwaysRetryJob executed (invocation $count)" }
        return JobResult.Retry("Simulated retry failure")
    }

    fun reset() {
        invocations.set(0)
    }
}