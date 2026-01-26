package dev.dailywombat.jobs.integration

import arrow.core.raise.either
import dev.dailywombat.jobs.actions.EnqueueJob
import dev.dailywombat.jobs.actions.EnqueueJobInput
import dev.dailywombat.jobs.integration.support.JobsIntegrationEnv
import dev.dailywombat.jobs.integration.support.ResetTestJobs
import dev.dailywombat.jobs.integration.support.db.JobsDb
import dev.dailywombat.jobs.integration.support.testjobs.SuccessJob
import dev.dailywombat.jobs.runtime.actions.LeaseJobs
import dev.dailywombat.jobs.runtime.actions.ReleaseStaleJobs
import io.kotest.matchers.shouldBe
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import java.util.*

/**
 * Tests that jobs with expired leases can be recovered and re-leased.
 *
 * When a worker crashes or times out, its leased jobs become "stale" and
 * should be recoverable by other workers.
 */
class LeaseExpiryRecoveryIT {

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
    fun `expired lease allows job to be re-leased by another worker`() {
        runBlocking {
            // Arrange: enqueue 1 job
            val jobId = enqueueJob()

            // Act: Worker A leases with short duration
            val workerAId = "worker-A"
            val leasedByA = context(JobsIntegrationEnv.pgRest) {
                either {
                    LeaseJobs(
                        workerId = workerAId,
                        limit = 1,
                        leaseDurationMinutes = 1
                    )
                }
            }.getOrNull()!!

            leasedByA.size shouldBe 1
            leasedByA[0].id shouldBe jobId

            // Verify job is processing with worker A
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)!!
                job.status shouldBe "processing"
                job.leaseOwner shouldBe workerAId
            }

            // Simulate crash: DO NOT complete the job
            // Manually expire the lease
            JobsDb.withConnection { conn ->
                JobsDb.expireLease(conn, jobId)
            }

            // Verify lease is expired
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)!!
                job.status shouldBe "processing" // Still processing until released
                (job.leaseUntil!! < java.time.Instant.now()) shouldBe true
            }

            // Release stale jobs
            val released = context(JobsIntegrationEnv.pgRest) {
                either { ReleaseStaleJobs() }
            }.getOrNull()!!

            released shouldBe 1

            // Verify job is now retrying and available
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)!!
                job.status shouldBe "retrying"
                job.leaseOwner shouldBe null
                job.leaseUntil shouldBe null
            }

            // Act: Worker B should be able to lease the job
            val workerBId = "worker-B"
            val leasedByB = context(JobsIntegrationEnv.pgRest) {
                either {
                    LeaseJobs(
                        workerId = workerBId,
                        limit = 1
                    )
                }
            }.getOrNull()!!

            // Assert: Worker B got the same job
            leasedByB.size shouldBe 1
            leasedByB[0].id shouldBe jobId

            // Verify job is now owned by worker B
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)!!
                job.status shouldBe "processing"
                job.leaseOwner shouldBe workerBId
            }
        }
    }

    @Test
    fun `stale lease recovery does not increment attempts`() {
        runBlocking {
            // Arrange: enqueue and lease
            val jobId = enqueueJob()

            context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = "worker-A", limit = 1) }
            }

            // Get initial attempts count
            val initialAttempts = JobsDb.withConnection { conn ->
                JobsDb.fetchJob(conn, jobId)!!.attempts
            }

            // Expire and release
            JobsDb.withConnection { conn ->
                JobsDb.expireLease(conn, jobId)
            }
            context(JobsIntegrationEnv.pgRest) {
                either { ReleaseStaleJobs() }
            }

            // Re-lease
            context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = "worker-B", limit = 1) }
            }

            // Assert: attempts should not have changed (stale != failure)
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)!!
                job.attempts shouldBe initialAttempts
            }
        }
    }

    @Test
    fun `lease count increments on re-lease after stale recovery`() {
        runBlocking {
            // Arrange: enqueue and lease
            val jobId = enqueueJob()

            context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = "worker-A", limit = 1) }
            }

            // Get initial lease count
            val initialLeaseCount = JobsDb.withConnection { conn ->
                JobsDb.fetchJob(conn, jobId)!!.leaseCount
            }
            initialLeaseCount shouldBe 1

            // Expire and release
            JobsDb.withConnection { conn ->
                JobsDb.expireLease(conn, jobId)
            }
            context(JobsIntegrationEnv.pgRest) {
                either { ReleaseStaleJobs() }
            }

            // Re-lease
            context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = "worker-B", limit = 1) }
            }

            // Assert: lease count should increment
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)!!
                job.leaseCount shouldBe initialLeaseCount + 1
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
}
