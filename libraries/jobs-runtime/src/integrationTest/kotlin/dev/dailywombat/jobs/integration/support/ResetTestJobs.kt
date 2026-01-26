package dev.dailywombat.jobs.integration.support

import dev.dailywombat.jobs.integration.support.testjobs.*
import io.github.oshai.kotlinlogging.KotlinLogging

object ResetTestJobs {
    internal val logger = KotlinLogging.logger {}

    operator fun invoke() {
        SuccessJob.reset()
        AlwaysRetryJob.reset()
        AlwaysFailJob.reset()
        FailThenSucceedJob.reset()
        FailUntilAttemptJob.reset()
        SlowJob.reset()
        LatchJob.reset()
        ThrowingJob.reset()
    }
}