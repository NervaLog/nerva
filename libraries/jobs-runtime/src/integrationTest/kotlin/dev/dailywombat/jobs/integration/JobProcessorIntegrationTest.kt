package dev.dailywombat.jobs.integration

import arrow.core.raise.either
import dev.dailywombat.jobs.actions.EnqueueJob
import dev.dailywombat.jobs.actions.EnqueueJobInput
import dev.dailywombat.jobs.integration.support.Await
import dev.dailywombat.jobs.integration.support.JobsIntegrationEnv
import dev.dailywombat.jobs.integration.support.ResetTestJobs
import dev.dailywombat.jobs.integration.support.db.JobsDb
import dev.dailywombat.jobs.integration.support.testjobs.*
import dev.dailywombat.jobs.runtime.processor.JobProcessor
import io.kotest.matchers.shouldBe
import io.kotest.matchers.shouldNotBe
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.fail
import java.util.*
import kotlin.time.Duration.Companion.seconds

class JobProcessorIntegrationTest {

    companion object {
        @BeforeAll
        @JvmStatic
        fun beforeAll() = JobsIntegrationEnv.start()

        // Don't stop containers - let Ryuk handle cleanup
        // Stopping between test classes breaks container restart
    }

    @BeforeEach
    fun beforeEach() {
        JobsIntegrationEnv.resetJobs()
        ResetTestJobs()
    }

    @Test
    fun `processBatch completes a successful job`() {
        runBlocking {
            // Arrange: enqueue a job
            val jobId = enqueueJob(SuccessJob.type)

            // Act: process it
            val processor = JobProcessor(batchSize = 10, maxAttempts = 3)
            context(JobsIntegrationEnv.pgRest) {
                either { processor.processBatch() }
                    .fold({ fail("processBatch failed: $it") }, { it })
            }

            // Assert: job is completed
            Await.jobStatus(jobId, "completed")
            SuccessJob.invocations.get() shouldBe 1

            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)
                job shouldNotBe null
                job!!.status shouldBe "completed"
                job.attempts shouldBe 0  // No failures
                job.completedAt shouldNotBe null
            }
        }
    }

    @Test
    fun `processBatch retries a failing job`() {
        runBlocking {
            // Arrange: enqueue a job that always retries
            val jobId = enqueueJob(AlwaysRetryJob.type)

            // Act: process it
            val processor = JobProcessor(batchSize = 10, maxAttempts = 3)
            context(JobsIntegrationEnv.pgRest) {
                either { processor.processBatch() }
                    .fold({ fail("processBatch failed: $it") }, { it })
            }

            // Assert: job is retrying (not failed yet, under max attempts)
            Await.jobStatus(jobId, "retrying")
            AlwaysRetryJob.invocations.get() shouldBe 1

            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)
                job shouldNotBe null
                job!!.status shouldBe "retrying"
                job.attempts shouldBe 1
                job.lastError shouldBe "Simulated retry failure"
            }
        }
    }

    @Test
    fun `processBatch fails a job after max attempts`() {
        runBlocking {
            // Arrange: enqueue a job
            val jobId = enqueueJob(AlwaysRetryJob.type)

            val processor = JobProcessor(batchSize = 10, maxAttempts = 3)

            // Act: process multiple times until exhausted
            repeat(3) { attempt ->
                // Make job available for processing
                if (attempt > 0) {
                    JobsDb.withConnection { conn ->
                        JobsDb.setAvailableAt(conn, jobId, JobsDb.now(conn))
                        JobsDb.setJobStatus(conn, jobId, "pending")
                    }
                }

                context(JobsIntegrationEnv.pgRest) {
                    either { processor.processBatch() }
                        .fold({ fail("processBatch attempt $attempt failed: $it") }, { it })
                }
            }

            // Assert: job is now failed
            Await.jobStatus(jobId, "failed")
            AlwaysRetryJob.invocations.get() shouldBe 3

            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)
                job shouldNotBe null
                job!!.status shouldBe "failed"
                job.attempts shouldBe 3
            }
        }
    }

    @Test
    fun `processBatch handles permanent failure`() {
        runBlocking {
            // Arrange: enqueue a job that permanently fails
            val jobId = enqueueJob(AlwaysFailJob.type)

            // Act: process it
            val processor = JobProcessor(batchSize = 10, maxAttempts = 3)
            context(JobsIntegrationEnv.pgRest) {
                either { processor.processBatch() }
                    .fold({ fail("processBatch failed: $it") }, { it })
            }

            // Assert: job is immediately failed (no retries)
            Await.jobStatus(jobId, "failed")
            AlwaysFailJob.invocations.get() shouldBe 1

            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)
                job shouldNotBe null
                job!!.status shouldBe "failed"
                job.lastError shouldBe "Simulated permanent failure"
            }
        }
    }

    @Test
    fun `processBatch handles job that throws exception`() {
        runBlocking {
            // Arrange: enqueue a job that throws
            val jobId = enqueueJob(ThrowingJob.type)

            // Act: process it
            val processor = JobProcessor(batchSize = 10, maxAttempts = 3)
            context(JobsIntegrationEnv.pgRest) {
                either { processor.processBatch() }
                    .fold({ fail("processBatch failed: $it") }, { it })
            }

            // Assert: job is retrying (exception caught, treated as retry)
            Await.jobStatus(jobId, "retrying")
            ThrowingJob.invocations.get() shouldBe 1

            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)
                job shouldNotBe null
                job!!.status shouldBe "retrying"
                job.lastError shouldNotBe null
                job.lastError!!.contains("Simulated exception") shouldBe true
            }
        }
    }

    @Test
    fun `processBatch processes multiple jobs in parallel`() {
        runBlocking {
            // Arrange: enqueue multiple slow jobs
            val jobIds = (1..5).map { enqueueJob(SlowJob.type, params = mapOf("delayMs" to 100)) }

            // Act: process them
            val processor = JobProcessor(batchSize = 10, concurrency = 5, maxAttempts = 3)
            val startTime = System.currentTimeMillis()
            context(JobsIntegrationEnv.pgRest) {
                either { processor.processBatch() }
                    .fold({ fail("processBatch failed: $it") }, { it })
            }
            val elapsed = System.currentTimeMillis() - startTime

            // Assert: all completed, and it was parallel (not sequential)
            jobIds.forEach { jobId ->
                Await.jobStatus(jobId, "completed")
            }
            SlowJob.invocations.get() shouldBe 5
            SlowJob.completions.get() shouldBe 5

            // If sequential, would take ~500ms. Parallel should be ~100-200ms
            // Allow some slack for container overhead
            (elapsed < 400) shouldBe true
        }
    }

    @Test
    fun `graceful shutdown stops accepting new batches`() {
        runBlocking {
            val processor = JobProcessor(batchSize = 10, maxAttempts = 3)

            // Request shutdown
            processor.requestShutdown()

            // Enqueue a job after shutdown requested
            enqueueJob(SuccessJob.type)

            // Process - should return 0 without leasing
            context(JobsIntegrationEnv.pgRest) {
                val processed = either { processor.processBatch() }
                    .fold({ fail("processBatch failed: $it") }, { it })
                processed shouldBe 0
            }

            // Job should still be pending
            Await.jobCount("pending", 1)
            SuccessJob.invocations.get() shouldBe 0
        }
    }

    @Test
    fun `graceful shutdown waits for in-flight jobs`() {
        runBlocking {
            // Arrange: enqueue a slow job
            val jobId = enqueueJob(SlowJob.type, params = mapOf("delayMs" to 500))

            val processor = JobProcessor(batchSize = 10, maxAttempts = 3)

            // Start processing in background
            val processingJob = launch {
                context(JobsIntegrationEnv.pgRest) {
                    either { processor.processBatch() }
                }
            }

            // Wait a bit for job to start
            Await.condition(timeout = 2.seconds) {
                SlowJob.invocations.get() > 0
            }

            // Request shutdown and wait
            val completed = processor.shutdown(timeout = 5.seconds)

            // Should have waited for job to complete
            completed shouldBe true
            processingJob.join()

            // Job should be completed
            Await.jobStatus(jobId, "completed")
            SlowJob.completions.get() shouldBe 1
        }
    }

    @Test
    fun `drainQueue processes all jobs until empty`() {
        runBlocking {
            // Arrange: enqueue multiple jobs
            repeat(5) { enqueueJob(SuccessJob.type) }

            // Act: drain the queue
            val processor = JobProcessor(batchSize = 2, maxAttempts = 3)
            context(JobsIntegrationEnv.pgRest) {
                val total = either { processor.drainQueue() }
                    .fold({ fail("drainQueue failed: $it") }, { it })
                total shouldBe 5
            }

            // Assert: all completed
            Await.queueDrained()
            SuccessJob.invocations.get() shouldBe 5
        }
    }

    // Helper to enqueue a job
    private fun enqueueJob(
        jobType: String,
        targetType: String = "test",
        targetId: UUID = UUID.randomUUID(),
        params: Map<String, Any>? = null
    ): UUID {
        return context(JobsIntegrationEnv.pgRest) {
            either {
                EnqueueJob(
                    EnqueueJobInput(
                        jobType = jobType,
                        targetType = targetType,
                        targetId = targetId,
                        params = params
                    )
                )
            }.fold(
                { fail("EnqueueJob failed: $it") },
                { it }
            )
        }
    }
}
