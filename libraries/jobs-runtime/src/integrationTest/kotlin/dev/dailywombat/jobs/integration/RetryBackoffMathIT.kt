package dev.dailywombat.jobs.integration

import arrow.core.raise.either
import dev.dailywombat.jobs.actions.EnqueueJob
import dev.dailywombat.jobs.actions.EnqueueJobInput
import dev.dailywombat.jobs.integration.support.JobsIntegrationEnv
import dev.dailywombat.jobs.integration.support.ResetTestJobs
import dev.dailywombat.jobs.integration.support.db.JobsDb
import dev.dailywombat.jobs.integration.support.testjobs.SuccessJob
import dev.dailywombat.jobs.runtime.actions.FailOrRetryJob
import dev.dailywombat.jobs.runtime.actions.FailOrRetryResult
import dev.dailywombat.jobs.runtime.actions.LeaseJobs
import io.kotest.matchers.shouldBe
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import java.time.Duration
import java.time.Instant
import java.util.*

/**
 * Tests exponential backoff with jitter.
 *
 * Backoff formula: min(base * 2^attempts, max) * jitter
 * Where jitter is (0.75 + random() * 0.5), giving range [0.75, 1.25]
 *
 * With base=1s and maxAttempts=3:
 * - 1st failure (attempts 0→1): delay = 1s * jitter = [0.75s, 1.25s]
 * - 2nd failure (attempts 1→2): delay = 2s * jitter = [1.5s, 2.5s]
 * - 3rd failure: job becomes failed (no retry)
 */
class RetryBackoffMathIT {

    companion object {
        @BeforeAll
        @JvmStatic
        fun beforeAll() {
            JobsIntegrationEnv.start()
        }

        // Time tolerance for assertions (±500ms as per spec)
        private val TIME_TOLERANCE_MS = 500L

        // Backoff configuration for tests
        private const val BACKOFF_SECONDS = 1
        private const val MAX_ATTEMPTS = 3
    }

    @BeforeEach
    fun beforeEach() {
        JobsIntegrationEnv.resetJobs()
        ResetTestJobs()
    }

    @Test
    fun `first failure sets status to retrying with correct backoff`() {
        runBlocking {
            // Arrange: enqueue and lease
            val jobId = enqueueJob()
            context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = "test-worker", limit = 1) }
            }

            val beforeFail = Instant.now()

            // Act: fail the job
            val result = context(JobsIntegrationEnv.pgRest) {
                either {
                    FailOrRetryJob(
                        jobId = jobId,
                        workerId = "test-worker",
                        maxAttempts = MAX_ATTEMPTS,
                        backoffSeconds = BACKOFF_SECONDS,
                        error = "boom"
                    )
                }
            }.getOrNull()!!

            // Assert: should be retrying
            result shouldBe FailOrRetryResult.RETRYING

            // Assert: status=retrying, attempts=1
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)!!
                job.status shouldBe "retrying"
                job.attempts shouldBe 1
                job.lastError shouldBe "boom"

                // Assert: available_at ~ now + 1s (with jitter range [0.75, 1.25])
                // Expected: beforeFail + 0.75s <= available_at <= now + 1.25s + tolerance
                val expectedMin = beforeFail.plusMillis(750 - TIME_TOLERANCE_MS)
                val expectedMax = Instant.now().plusMillis(1250 + TIME_TOLERANCE_MS)

                assertTimeInRange(
                    job.availableAt!!,
                    expectedMin,
                    expectedMax,
                    "First failure available_at"
                )
            }
        }
    }

    @Test
    fun `second failure doubles backoff`() {
        runBlocking {
            // Arrange: enqueue, lease, fail once
            val jobId = enqueueJob()
            context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = "test-worker", limit = 1) }
            }
            context(JobsIntegrationEnv.pgRest) {
                either {
                    FailOrRetryJob(
                        jobId = jobId,
                        workerId = "test-worker",
                        maxAttempts = MAX_ATTEMPTS,
                        backoffSeconds = BACKOFF_SECONDS,
                        error = "first failure"
                    )
                }
            }

            // Make job immediately available and lease again
            JobsDb.withConnection { conn ->
                JobsDb.setAvailableAt(conn, jobId, Instant.now().minusSeconds(1))
            }
            context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = "test-worker", limit = 1) }
            }

            val beforeFail = Instant.now()

            // Act: fail second time
            val result = context(JobsIntegrationEnv.pgRest) {
                either {
                    FailOrRetryJob(
                        jobId = jobId,
                        workerId = "test-worker",
                        maxAttempts = MAX_ATTEMPTS,
                        backoffSeconds = BACKOFF_SECONDS,
                        error = "second failure"
                    )
                }
            }.getOrNull()!!

            // Assert: still retrying
            result shouldBe FailOrRetryResult.RETRYING

            // Assert: status=retrying, attempts=2
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)!!
                job.status shouldBe "retrying"
                job.attempts shouldBe 2

                // Assert: available_at ~ now + 2s (with jitter range [1.5, 2.5])
                val expectedMin = beforeFail.plusMillis(1500 - TIME_TOLERANCE_MS)
                val expectedMax = Instant.now().plusMillis(2500 + TIME_TOLERANCE_MS)

                assertTimeInRange(
                    job.availableAt!!,
                    expectedMin,
                    expectedMax,
                    "Second failure available_at"
                )
            }
        }
    }

    @Test
    fun `third failure marks job as failed`() {
        runBlocking {
            // Arrange: enqueue, lease, fail twice
            val jobId = enqueueJob()

            // First failure
            context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = "test-worker", limit = 1) }
            }
            context(JobsIntegrationEnv.pgRest) {
                either {
                    FailOrRetryJob(
                        jobId = jobId,
                        workerId = "test-worker",
                        maxAttempts = MAX_ATTEMPTS,
                        backoffSeconds = BACKOFF_SECONDS,
                        error = "first"
                    )
                }
            }

            // Second failure
            JobsDb.withConnection { conn ->
                JobsDb.setAvailableAt(conn, jobId, Instant.now().minusSeconds(1))
            }
            context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = "test-worker", limit = 1) }
            }
            context(JobsIntegrationEnv.pgRest) {
                either {
                    FailOrRetryJob(
                        jobId = jobId,
                        workerId = "test-worker",
                        maxAttempts = MAX_ATTEMPTS,
                        backoffSeconds = BACKOFF_SECONDS,
                        error = "second"
                    )
                }
            }

            // Third failure
            JobsDb.withConnection { conn ->
                JobsDb.setAvailableAt(conn, jobId, Instant.now().minusSeconds(1))
            }
            context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = "test-worker", limit = 1) }
            }

            // Act: third failure
            val result = context(JobsIntegrationEnv.pgRest) {
                either {
                    FailOrRetryJob(
                        jobId = jobId,
                        workerId = "test-worker",
                        maxAttempts = MAX_ATTEMPTS,
                        backoffSeconds = BACKOFF_SECONDS,
                        error = "final boom"
                    )
                }
            }.getOrNull()!!

            // Assert: should be failed
            result shouldBe FailOrRetryResult.FAILED

            // Assert: status=failed, attempts=3, last_error contains message
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)!!
                job.status shouldBe "failed"
                job.attempts shouldBe 3
                job.lastError shouldBe "final boom"
            }
        }
    }

    @Test
    fun `backoff is capped at max_backoff_seconds`() {
        runBlocking {
            // Arrange: enqueue and lease with high attempt count scenario
            // Using maxBackoff of 2 seconds, and base of 10 seconds
            // After first failure: min(10 * 2^0, 2) = 2s (capped)
            val jobId = enqueueJob()
            context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = "test-worker", limit = 1) }
            }

            val beforeFail = Instant.now()

            // Act: fail with high base backoff but low cap
            val result = context(JobsIntegrationEnv.pgRest) {
                either {
                    FailOrRetryJob(
                        jobId = jobId,
                        workerId = "test-worker",
                        maxAttempts = 10,
                        backoffSeconds = 10,      // Would be 10s without cap
                        maxBackoffSeconds = 2,    // Cap at 2s
                        error = "test"
                    )
                }
            }.getOrNull()!!

            result shouldBe FailOrRetryResult.RETRYING

            // Assert: backoff should be capped at 2s * jitter = [1.5s, 2.5s]
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)!!

                val expectedMin = beforeFail.plusMillis(1500 - TIME_TOLERANCE_MS)
                val expectedMax = Instant.now().plusMillis(2500 + TIME_TOLERANCE_MS)

                assertTimeInRange(
                    job.availableAt!!,
                    expectedMin,
                    expectedMax,
                    "Capped backoff available_at"
                )
            }
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

    private fun assertTimeInRange(
        actual: Instant,
        min: Instant,
        max: Instant,
        description: String
    ) {
        if (actual.isBefore(min) || actual.isAfter(max)) {
            throw AssertionError(
                """
                |$description out of expected range
                |  Expected: [$min, $max]
                |  Actual:   $actual
                |  Delta from min: ${Duration.between(min, actual).toMillis()}ms
                |  Delta from max: ${Duration.between(actual, max).toMillis()}ms
                |${JobsIntegrationEnv.dumpState()}
                """.trimMargin()
            )
        }
    }
}
