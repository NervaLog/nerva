package dev.dailywombat.jobs.integration.support.testjobs

import dev.dailywombat.jobs.Job
import dev.dailywombat.jobs.JobResult
import dev.dailywombat.jobs.integration.support.ResetTestJobs.logger
import kotlinx.coroutines.delay
import java.util.concurrent.atomic.AtomicInteger

/**
 * Test job with configurable delay.
 */
object SlowJob : Job<SlowJob.Params>(
    type = "test_slow",
    paramsClass = Params::class
) {
    data class Params(val delayMs: Long = 100)

    val invocations = AtomicInteger(0)
    val completions = AtomicInteger(0)

    override suspend fun invoke(params: Params): JobResult {
        invocations.incrementAndGet()
        logger.debug { "SlowJob starting, will delay ${params.delayMs}ms" }
        delay(params.delayMs)
        completions.incrementAndGet()
        logger.debug { "SlowJob completed" }
        return JobResult.Success
    }

    fun reset() {
        invocations.set(0)
        completions.set(0)
    }
}