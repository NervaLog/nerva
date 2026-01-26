package dev.dailywombat.jobs.integration.support.testjobs

import dev.dailywombat.jobs.JobResult
import dev.dailywombat.jobs.UnitJob
import dev.dailywombat.jobs.integration.support.ResetTestJobs.logger
import java.util.concurrent.atomic.AtomicInteger

/**
 * Test job that throws an exception (to test exception handling).
 */
object ThrowingJob : UnitJob("test_throwing") {
    val invocations = AtomicInteger(0)

    override suspend fun invoke(): JobResult {
        invocations.incrementAndGet()
        logger.debug { "ThrowingJob about to throw" }
        throw RuntimeException("Simulated exception from ThrowingJob")
    }

    fun reset() {
        invocations.set(0)
    }
}