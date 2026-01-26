package dev.dailywombat.jobs.integration

import arrow.core.raise.either
import dev.dailywombat.jobs.actions.EnqueueJob
import dev.dailywombat.jobs.actions.EnqueueJobInput
import dev.dailywombat.jobs.integration.support.Await
import dev.dailywombat.jobs.integration.support.JobsIntegrationEnv
import dev.dailywombat.jobs.integration.support.ResetTestJobs
import dev.dailywombat.jobs.integration.support.TestWorker
import dev.dailywombat.jobs.integration.support.db.JobsDb
import dev.dailywombat.jobs.integration.support.testjobs.SuccessJob
import io.kotest.matchers.shouldBe
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import java.util.*
import kotlin.time.Duration.Companion.seconds

/**
 * End-to-end tests for worker queue draining.
 *
 * Tests that a worker can process all jobs in the queue to completion.
 */
class WorkerDrainsQueueIT {

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
    fun `worker processes all jobs to completion`() {
        runBlocking {
            // Arrange: start worker first
            worker = TestWorker(
                handlers = listOf(SuccessJob),
                batchSize = 10,
                maxAttempts = 3
            )
            worker!!.start()

            // Enqueue N=50 jobs
            val jobCount = 50
            (1..jobCount).map { enqueueJob() }

            // Assert: await queue drained
            Await.queueDrained(timeout = 15.seconds)

            // Assert: worker processed all jobs
            worker!!.processedCount.get() shouldBe jobCount

            // Assert: all jobs completed
            SuccessJob.invocations.get() shouldBe jobCount

            // Assert: all jobs have completed status
            JobsDb.withConnection { conn ->
                val counts = JobsDb.countByStatus(conn)
                counts["completed"] shouldBe jobCount
                counts["pending"] shouldBe null
                counts["processing"] shouldBe null
                counts["retrying"] shouldBe null
                counts["failed"] shouldBe null
            }
        }
    }

    @Test
    fun `worker handles empty queue gracefully`() {
        runBlocking {
            // Arrange: start worker with empty queue
            worker = TestWorker(
                handlers = listOf(SuccessJob),
                batchSize = 10
            )
            worker!!.start()

            // Wait a bit for worker to poll
            kotlinx.coroutines.delay(500)

            // Assert: no jobs processed
            worker!!.processedCount.get() shouldBe 0

            // Enqueue a single job
            enqueueJob()

            // Assert: job is processed
            Await.queueDrained(timeout = 10.seconds)
            worker!!.processedCount.get() shouldBe 1
        }
    }

    @Test
    fun `worker processes jobs across multiple batches`() {
        runBlocking {
            // Arrange: start worker with small batch size
            worker = TestWorker(
                handlers = listOf(SuccessJob),
                batchSize = 5  // Small batch
            )
            worker!!.start()

            // Enqueue more jobs than batch size
            val jobCount = 23
            repeat(jobCount) { enqueueJob() }

            // Assert: queue drained
            Await.queueDrained(timeout = 15.seconds)

            // Assert: processed all jobs
            worker!!.processedCount.get() shouldBe jobCount

            // Assert: multiple batches were processed (23 jobs / 5 batch = at least 5 batches)
            (worker!!.batchCount.get() >= 5) shouldBe true
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
