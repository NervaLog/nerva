package dev.dailywombat.jobs.integration

import arrow.core.raise.either
import dev.dailywombat.jobs.actions.EnqueueJob
import dev.dailywombat.jobs.actions.EnqueueJobInput
import dev.dailywombat.jobs.integration.support.Await
import dev.dailywombat.jobs.integration.support.JobsIntegrationEnv
import dev.dailywombat.jobs.integration.support.ResetTestJobs
import dev.dailywombat.jobs.integration.support.TestWorker
import dev.dailywombat.jobs.integration.support.testjobs.SuccessJob
import io.kotest.matchers.shouldBe
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import java.util.*
import kotlin.time.Duration.Companion.seconds

/**
 * Tests that jobs are still processed when NOTIFY is missed.
 *
 * When the LISTEN connection is down, the worker should fall back to
 * polling and still process jobs within a reasonable timeframe.
 */
class NotifyMissedStillWorksIT {

    companion object {
        @BeforeAll
        @JvmStatic
        fun beforeAll() {
            JobsIntegrationEnv.start()
        }
    }

    private var worker: TestWorker? = null

    @BeforeEach
    fun beforeEach() {
        JobsIntegrationEnv.resetJobs()
        ResetTestJobs()
    }

    @AfterEach
    fun afterEach() {
        runBlocking {
            worker?.stop()
        }
        worker = null
    }

    @Test
    fun `job is processed via polling when NOTIFY listener is stopped`() {
        runBlocking {
            // Arrange: start worker with short poll timeout
            val pollTimeoutMs = 2000L  // 2 second poll
            worker = TestWorker(
                handlers = listOf(SuccessJob),
                batchSize = 10,
                pollTimeoutMs = pollTimeoutMs
            )
            worker!!.start()

            // Wait for worker to establish LISTEN connection
            delay(1000)

            // Stop only the LISTEN listener (worker loop continues)
            worker!!.stopListenerOnly()

            // Wait a bit to ensure listener is fully stopped
            delay(500)

            // Act: enqueue job (NOTIFY will be missed)
            val jobId = enqueueJob()

            // Assert: job should still complete via polling
            // Allow: poll timeout + processing time + cushion
            val maxWait = pollTimeoutMs + 3000  // 5 seconds total

            Await.jobStatus(
                jobId,
                "completed",
                timeout = (maxWait / 1000 + 5).seconds
            )

            // Assert: job was processed
            SuccessJob.invocations.get() shouldBe 1
        }
    }

    @Test
    fun `multiple jobs are processed via polling`() {
        runBlocking {
            // Arrange: start worker with short poll
            val pollTimeoutMs = 2000L
            worker = TestWorker(
                handlers = listOf(SuccessJob),
                batchSize = 10,
                pollTimeoutMs = pollTimeoutMs
            )
            worker!!.start()

            delay(1000)
            worker!!.stopListenerOnly()
            delay(500)

            // Act: enqueue multiple jobs
            val jobIds = (1..5).map { enqueueJob() }

            // Assert: all jobs complete via polling
            val maxWait = pollTimeoutMs * 2 + 5000  // Allow multiple poll cycles

            jobIds.forEach { jobId ->
                Await.jobStatus(
                    jobId,
                    "completed",
                    timeout = (maxWait / 1000 + 5).seconds
                )
            }

            SuccessJob.invocations.get() shouldBe 5
        }
    }

    @Test
    fun `job enqueued before listener stop is still processed`() {
        runBlocking {
            // Arrange: start worker
            val pollTimeoutMs = 2000L
            worker = TestWorker(
                handlers = listOf(SuccessJob),
                batchSize = 10,
                pollTimeoutMs = pollTimeoutMs
            )
            worker!!.start()

            delay(1000)

            // Enqueue job (with NOTIFY active)
            val job1 = enqueueJob()

            // Wait for NOTIFY to propagate and onWake to be invoked
            delay(500)

            // Stop listener
            worker!!.stopListenerOnly()

            // Enqueue another job (NOTIFY will miss this one)
            delay(500)
            val job2 = enqueueJob()

            // Assert: both jobs complete
            Await.jobStatus(job1, "completed", timeout = 10.seconds)
            Await.jobStatus(job2, "completed", timeout = 10.seconds)

            SuccessJob.invocations.get() shouldBe 2
        }
    }

    @Test
    fun `polling continues when no jobs available`() {
        runBlocking {
            // Arrange: start worker with no listener, short poll
            val pollTimeoutMs = 1000L
            worker = TestWorker(
                handlers = listOf(SuccessJob),
                batchSize = 10,
                pollTimeoutMs = pollTimeoutMs
            )
            worker!!.start()

            delay(500)
            worker!!.stopListenerOnly()

            // Let worker poll a few times with empty queue
            delay(pollTimeoutMs * 3)

            // Enqueue job
            val jobId = enqueueJob()

            // Assert: job is processed on next poll
            Await.jobStatus(jobId, "completed", timeout = 5.seconds)

            SuccessJob.invocations.get() shouldBe 1
        }
    }

    private fun enqueueJob(): UUID {
        return context(JobsIntegrationEnv.pgRest) {
            either {
                EnqueueJob(
                    EnqueueJobInput(
                        jobType = SuccessJob.type,
                        targetType = "test",
                        targetId = UUID.randomUUID()
                    )
                )
            }
        }.getOrNull() ?: throw AssertionError("Failed to enqueue job\n${JobsIntegrationEnv.dumpState()}")
    }
}
