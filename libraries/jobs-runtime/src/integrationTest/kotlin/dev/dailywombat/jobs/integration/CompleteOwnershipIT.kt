package dev.dailywombat.jobs.integration

import arrow.core.raise.either
import dev.dailywombat.jobs.actions.EnqueueJob
import dev.dailywombat.jobs.actions.EnqueueJobInput
import dev.dailywombat.jobs.integration.support.JobsIntegrationEnv
import dev.dailywombat.jobs.integration.support.ResetTestJobs
import dev.dailywombat.jobs.integration.support.db.JobsDb
import dev.dailywombat.jobs.integration.support.testjobs.SuccessJob
import dev.dailywombat.jobs.runtime.actions.CompleteJob
import dev.dailywombat.jobs.runtime.actions.FailOrRetryJob
import dev.dailywombat.jobs.runtime.actions.FailOrRetryResult
import dev.dailywombat.jobs.runtime.actions.LeaseJobs
import io.kotest.matchers.shouldBe
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import java.util.*

/**
 * Tests that only the lease owner can complete or fail a job.
 *
 * This prevents race conditions where one worker completes another's job.
 */
class CompleteOwnershipIT {

    companion object {
        @BeforeAll
        @JvmStatic
        fun beforeAll() {
            JobsIntegrationEnv.start()
        }
    }

    @BeforeEach
    fun beforeEach() {
        JobsIntegrationEnv.resetJobs()
        ResetTestJobs()
    }

    @Test
    fun `non-owner cannot complete job`() {
        runBlocking {
            // Arrange: enqueue and lease with worker A
            val jobId = enqueueJob()
            val workerA = "worker-A"

            context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = workerA, limit = 1) }
            }

            // Act: worker B tries to complete
            val workerB = "worker-B"
            val completed = context(JobsIntegrationEnv.pgRest) {
                either { CompleteJob(jobId, workerId = workerB) }
            }.getOrNull()!!

            // Assert: should return false (not completed)
            completed shouldBe false

            // Job should still be processing, not completed
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)!!
                job.status shouldBe "processing"
                job.leaseOwner shouldBe workerA
            }
        }
    }

    @Test
    fun `owner can complete job`() {
        runBlocking {
            // Arrange: enqueue and lease with worker A
            val jobId = enqueueJob()
            val workerA = "worker-A"

            context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = workerA, limit = 1) }
            }

            // Act: worker A completes
            val completed = context(JobsIntegrationEnv.pgRest) {
                either { CompleteJob(jobId, workerId = workerA) }
            }.getOrNull()!!

            // Assert: should succeed
            completed shouldBe true

            // Job should be completed
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)!!
                job.status shouldBe "completed"
                job.leaseOwner shouldBe null
                job.completedAt shouldNotBeNull "completedAt"
            }
        }
    }

    @Test
    fun `complete without workerId succeeds for any processing job`() {
        runBlocking {
            // Arrange: enqueue and lease with worker A
            val jobId = enqueueJob()

            context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = "worker-A", limit = 1) }
            }

            // Act: complete without specifying workerId
            val completed = context(JobsIntegrationEnv.pgRest) {
                either { CompleteJob(jobId, workerId = null) }
            }.getOrNull()!!

            // Assert: should succeed
            completed shouldBe true

            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)!!
                job.status shouldBe "completed"
            }
        }
    }

    @Test
    fun `non-owner cannot fail job`() {
        runBlocking {
            // Arrange: enqueue and lease with worker A
            val jobId = enqueueJob()
            val workerA = "worker-A"

            context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = workerA, limit = 1) }
            }

            // Act: worker B tries to fail
            val workerB = "worker-B"
            val result = context(JobsIntegrationEnv.pgRest) {
                either {
                    FailOrRetryJob(
                        jobId = jobId,
                        workerId = workerB,
                        error = "Worker B error"
                    )
                }
            }.getOrNull()!!

            // Assert: should return NOT_FOUND (can't update job not owned by worker)
            result shouldBe FailOrRetryResult.NOT_FOUND

            // Job should still be processing with original owner
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)!!
                job.status shouldBe "processing"
                job.leaseOwner shouldBe workerA
            }
        }
    }

    @Test
    fun `owner can fail job`() {
        runBlocking {
            // Arrange: enqueue and lease with worker A
            val jobId = enqueueJob()
            val workerA = "worker-A"

            context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = workerA, limit = 1) }
            }

            // Act: worker A fails with maxAttempts=1 to force failure
            val result = context(JobsIntegrationEnv.pgRest) {
                either {
                    FailOrRetryJob(
                        jobId = jobId,
                        workerId = workerA,
                        maxAttempts = 1,
                        error = "Worker A error"
                    )
                }
            }.getOrNull()!!

            // Assert: should return FAILED
            result shouldBe FailOrRetryResult.FAILED

            // Job should be failed
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)!!
                job.status shouldBe "failed"
                job.lastError shouldBe "Worker A error"
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

    private infix fun <T> T?.shouldNotBeNull(name: String) {
        if (this == null) {
            throw AssertionError("Expected $name to not be null\n${JobsIntegrationEnv.dumpState()}")
        }
    }
}
