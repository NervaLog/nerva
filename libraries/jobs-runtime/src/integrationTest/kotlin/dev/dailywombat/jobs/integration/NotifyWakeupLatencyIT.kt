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
 * Tests LISTEN/NOTIFY wakeup latency.
 *
 * When a job is enqueued, the worker should be notified via PostgreSQL
 * NOTIFY and process the job quickly (< 2 seconds).
 */
class NotifyWakeupLatencyIT {

    companion object {
        @BeforeAll
        @JvmStatic
        fun beforeAll() {
            JobsIntegrationEnv.start()
        }

        // Maximum acceptable latency for NOTIFY-driven processing
        private const val MAX_LATENCY_MS = 2000L
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
    fun `job is processed quickly via NOTIFY wakeup`() {
        runBlocking {
            // Arrange: start worker with LISTEN/NOTIFY enabled
            // Use long poll timeout so we know it was NOTIFY that woke us
            worker = TestWorker(
                handlers = listOf(SuccessJob),
                batchSize = 10,
                pollTimeoutMs = 30000  // 30 second poll - if job completes fast, it was NOTIFY
            )
            worker!!.start()

            // Wait for worker to be idle and LISTEN connection established
            delay(1000)

            // Record start time
            val startTime = System.currentTimeMillis()

            // Act: enqueue job
            val jobId = enqueueJob()

            // Assert: job completes within latency threshold
            Await.jobStatus(jobId, "completed", timeout = 5.seconds)

            val elapsed = System.currentTimeMillis() - startTime

            // Assert: processing was fast (NOTIFY worked)
            if (elapsed > MAX_LATENCY_MS) {
                throw AssertionError(
                    """
                    |Job processing took too long: ${elapsed}ms (max: ${MAX_LATENCY_MS}ms)
                    |This suggests NOTIFY wakeup may not be working.
                    |${JobsIntegrationEnv.dumpState()}
                    """.trimMargin()
                )
            }

            // Assert: job was processed
            SuccessJob.invocations.get() shouldBe 1
        }
    }

    @Test
    fun `multiple rapid enqueues are coalesced efficiently`() {
        runBlocking {
            // Arrange: start worker
            worker = TestWorker(
                handlers = listOf(SuccessJob),
                batchSize = 10,
                pollTimeoutMs = 30000
            )
            worker!!.start()

            delay(1000)

            val startTime = System.currentTimeMillis()

            // Act: enqueue multiple jobs rapidly
            val jobIds = (1..5).map { enqueueJob() }

            // Assert: all jobs complete quickly
            jobIds.forEach { jobId ->
                Await.jobStatus(jobId, "completed", timeout = 5.seconds)
            }

            val elapsed = System.currentTimeMillis() - startTime

            // Assert: all jobs processed within reasonable time
            // Multiple NOTIFYs should be coalesced, so total time should still be fast
            if (elapsed > MAX_LATENCY_MS * 2) {  // Allow 2x for multiple jobs
                throw AssertionError(
                    """
                    |Multiple jobs took too long: ${elapsed}ms
                    |${JobsIntegrationEnv.dumpState()}
                    """.trimMargin()
                )
            }

            SuccessJob.invocations.get() shouldBe 5
        }
    }

    @Test
    fun `enqueue while worker is processing still triggers wakeup`() {
        runBlocking {
            // Arrange: start worker
            worker = TestWorker(
                handlers = listOf(SuccessJob),
                batchSize = 1,  // Process one at a time
                pollTimeoutMs = 30000
            )
            worker!!.start()

            delay(1000)

            // Act: enqueue first job
            val job1 = enqueueJob()

            // Wait a tiny bit then enqueue second job (while first might be processing)
            delay(50)
            val job2 = enqueueJob()

            // Assert: both jobs complete quickly
            val startTime = System.currentTimeMillis()
            Await.jobStatus(job1, "completed", timeout = 5.seconds)
            Await.jobStatus(job2, "completed", timeout = 5.seconds)
            val elapsed = System.currentTimeMillis() - startTime

            // Both should complete quickly
            if (elapsed > MAX_LATENCY_MS * 2) {
                throw AssertionError(
                    """
                    |Jobs took too long: ${elapsed}ms
                    |${JobsIntegrationEnv.dumpState()}
                    """.trimMargin()
                )
            }

            SuccessJob.invocations.get() shouldBe 2
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
