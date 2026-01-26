package dev.dailywombat.jobs.integration.support.testjobs

import dev.dailywombat.jobs.JobResult
import dev.dailywombat.jobs.UnitJob
import dev.dailywombat.jobs.integration.support.ResetTestJobs.logger
import java.util.concurrent.atomic.AtomicInteger

/**
 * Test job that always fails permanently (no retry).
 */
object AlwaysFailJob : UnitJob("test_always_fail") {
    val invocations = AtomicInteger(0)

    override suspend fun invoke(): JobResult {
        invocations.incrementAndGet()
        logger.debug { "AlwaysFailJob executed" }
        return JobResult.Fail("Simulated permanent failure")
    }

    fun reset() {
        invocations.set(0)
    }
}