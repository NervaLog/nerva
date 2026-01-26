package dev.dailywombat.jobs.integration

import arrow.core.raise.either
import dev.dailywombat.jobs.actions.EnqueueJob
import dev.dailywombat.jobs.actions.EnqueueJobInput
import dev.dailywombat.jobs.integration.support.Await
import dev.dailywombat.jobs.integration.support.JobsIntegrationEnv
import dev.dailywombat.jobs.integration.support.ResetTestJobs
import dev.dailywombat.jobs.integration.support.TestWorker
import dev.dailywombat.jobs.integration.support.db.JobsDb
import dev.dailywombat.jobs.integration.support.testjobs.FailUntilAttemptJob
import io.kotest.matchers.shouldBe
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import java.util.*
import kotlin.time.Duration.Companion.seconds

/**
 * Tests that jobs can fail K times and then succeed.
 *
 * This validates the retry mechanism works end-to-end with a real worker.
 */
class WorkerRetryThenSuccessIT {

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
    fun `job fails twice then succeeds on third attempt`() {
        runBlocking {
            // Arrange: start worker with short backoff for faster test
            worker = TestWorker(
                handlers = listOf(FailUntilAttemptJob),
                batchSize = 10,
                maxAttempts = 5,    // Allow enough retries
                backoffSeconds = 1  // Short backoff
            )
            worker!!.start()

            // Enqueue job that succeeds on 3rd attempt
            val targetId = UUID.randomUUID()
            val jobId = context(JobsIntegrationEnv.pgRest) {
                either {
                    EnqueueJob(
                        EnqueueJobInput(
                            jobType = FailUntilAttemptJob.type,
                            targetType = "test",
                            targetId = targetId,
                            params = mapOf(
                                "succeedOnAttempt" to 3,
                                "targetId" to targetId.toString()
                            )
                        )
                    )
                }
            }.getOrNull() ?: throw AssertionError("Failed to enqueue job")

            // Assert: job eventually completes
            Await.jobStatus(jobId, "completed", timeout = 30.seconds)

            // Assert: job was invoked 3 times (2 failures + 1 success)
            FailUntilAttemptJob.getInvocations(targetId.toString()) shouldBe 3

            // Assert: attempts count in DB reflects failures
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)!!
                job.status shouldBe "completed"
                // attempts = 2 (two failures that incremented attempt count)
                // The third invocation succeeded without incrementing attempts
                job.attempts shouldBe 2
            }
        }
    }

    @Test
    fun `job exhausts retries and fails permanently`() {
        runBlocking {
            // Arrange: start worker with limited retries
            worker = TestWorker(
                handlers = listOf(FailUntilAttemptJob),
                batchSize = 10,
                maxAttempts = 3,    // Only 3 attempts allowed
                backoffSeconds = 1
            )
            worker!!.start()

            // Enqueue job that would need 5 attempts to succeed
            val targetId = UUID.randomUUID()
            val jobId = context(JobsIntegrationEnv.pgRest) {
                either {
                    EnqueueJob(
                        EnqueueJobInput(
                            jobType = FailUntilAttemptJob.type,
                            targetType = "test",
                            targetId = targetId,
                            params = mapOf(
                                "succeedOnAttempt" to 5,  // Would need 5 attempts
                                "targetId" to targetId.toString()
                            )
                        )
                    )
                }
            }.getOrNull() ?: throw AssertionError("Failed to enqueue job")

            // Assert: job eventually fails (exhausts retries)
            Await.jobStatus(jobId, "failed", timeout = 30.seconds)

            // Assert: job was invoked maxAttempts times
            FailUntilAttemptJob.getInvocations(targetId.toString()) shouldBe 3

            // Assert: DB state reflects failure
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)!!
                job.status shouldBe "failed"
                job.attempts shouldBe 3
                job.lastError shouldNotBeNull "lastError"
            }
        }
    }

    @Test
    fun `multiple jobs with different retry counts all complete`() {
        runBlocking {
            // Arrange: start worker
            worker = TestWorker(
                handlers = listOf(FailUntilAttemptJob),
                batchSize = 10,
                maxAttempts = 5,
                backoffSeconds = 1
            )
            worker!!.start()

            // Enqueue jobs with different retry requirements
            val jobs = listOf(
                enqueueFailUntil(succeedOnAttempt = 1),  // Succeeds immediately
                enqueueFailUntil(succeedOnAttempt = 2),  // 1 failure, then success
                enqueueFailUntil(succeedOnAttempt = 3),  // 2 failures, then success
            )

            // Assert: all jobs complete
            jobs.forEach { jobId ->
                Await.jobStatus(jobId, "completed", timeout = 30.seconds)
            }

            // Assert: all jobs are completed
            JobsDb.withConnection { conn ->
                val counts = JobsDb.countByStatus(conn)
                counts["completed"] shouldBe 3
            }
        }
    }

    private fun enqueueFailUntil(succeedOnAttempt: Int): UUID {
        val targetId = UUID.randomUUID()
        return context(JobsIntegrationEnv.pgRest) {
            either {
                EnqueueJob(
                    EnqueueJobInput(
                        jobType = FailUntilAttemptJob.type,
                        targetType = "test",
                        targetId = targetId,
                        params = mapOf(
                            "succeedOnAttempt" to succeedOnAttempt,
                            "targetId" to targetId.toString()
                        )
                    )
                )
            }
        }.getOrNull() ?: throw AssertionError("Failed to enqueue job\n${JobsIntegrationEnv.dumpState()}")
    }

    private infix fun <T> T?.shouldNotBeNull(name: String) {
        if (this == null) {
            throw AssertionError("Expected $name to not be null\n${JobsIntegrationEnv.dumpState()}")
        }
    }
}
