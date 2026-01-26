package dev.dailywombat.jobs.integration.support.testjobs

import dev.dailywombat.jobs.JobResult
import dev.dailywombat.jobs.UnitJob
import dev.dailywombat.jobs.integration.support.ResetTestJobs.logger
import java.util.concurrent.atomic.AtomicInteger

/**
 * Test job that always succeeds immediately.
 */
object SuccessJob : UnitJob("test_success") {
    val invocations = AtomicInteger(0)

    override suspend fun invoke(): JobResult {
        invocations.incrementAndGet()
        logger.debug { "SuccessJob executed" }
        return JobResult.Success
    }

    fun reset() {
        invocations.set(0)
    }
}

