package dev.dailywombat.jobs.integration

import arrow.core.raise.either
import dev.dailywombat.jobs.actions.EnqueueJob
import dev.dailywombat.jobs.actions.EnqueueJobInput
import dev.dailywombat.jobs.integration.support.Await
import dev.dailywombat.jobs.integration.support.JobsIntegrationEnv
import dev.dailywombat.jobs.integration.support.ResetTestJobs
import dev.dailywombat.jobs.integration.support.db.JobsDb
import dev.dailywombat.jobs.integration.support.testjobs.SuccessJob
import dev.dailywombat.jobs.runtime.actions.LeaseJobs
import io.kotest.matchers.shouldBe
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import java.time.Instant
import java.util.*
import kotlin.time.Duration.Companion.seconds

/**
 * Tests that jobs respect available_at scheduling.
 *
 * Jobs should not be leasable until their available_at time has passed.
 */
class AvailableAtGatingIT {

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
    fun `job with future available_at is not leased immediately`() {
        runBlocking {
            // Arrange: enqueue job with available_at = now + 2 seconds
            val futureTime = Instant.now().plusSeconds(2)
            val jobId = context(JobsIntegrationEnv.pgRest) {
                either {
                    EnqueueJob(
                        EnqueueJobInput(
                            jobType = SuccessJob.type,
                            targetType = "test",
                            targetId = UUID.randomUUID(),
                            availableAt = futureTime
                        )
                    )
                }
            }.getOrNull() ?: throw AssertionError("Failed to enqueue job\n${JobsIntegrationEnv.dumpState()}")

            // Act: try to lease immediately
            val immediateLeased = context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = "test-worker", limit = 10) }
            }.getOrNull()!!

            // Assert: no jobs should be leased (job is gated)
            immediateLeased.size shouldBe 0

            // Verify job is still pending
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)!!
                job.status shouldBe "pending"
            }

            // Act: wait for available_at to pass, then lease
            Await.condition(
                timeout = 5.seconds,
                description = "job to become available"
            ) {
                val leased = context(JobsIntegrationEnv.pgRest) {
                    either { LeaseJobs(workerId = "test-worker", limit = 10) }
                }.getOrNull() ?: emptyList()
                leased.isNotEmpty()
            }

            // Assert: job should now be leased
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)!!
                job.status shouldBe "processing"
            }
        }
    }

    @Test
    fun `immediately available job is leased`() {
        runBlocking {
            // Arrange: enqueue job with available_at = now (default)
            val jobId = context(JobsIntegrationEnv.pgRest) {
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

            // Act: lease immediately
            val leased = context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = "test-worker", limit = 10) }
            }.getOrNull()!!

            // Assert: job should be leased
            leased.size shouldBe 1
            leased[0].id shouldBe jobId
        }
    }

    @Test
    fun `only available jobs are leased when mixed`() {
        runBlocking {
            // Arrange: enqueue one available job and one future job
            val availableId = context(JobsIntegrationEnv.pgRest) {
                either {
                    EnqueueJob(
                        EnqueueJobInput(
                            jobType = SuccessJob.type,
                            targetType = "test",
                            targetId = UUID.randomUUID()
                        )
                    )
                }
            }.getOrNull()!!

            val futureId = context(JobsIntegrationEnv.pgRest) {
                either {
                    EnqueueJob(
                        EnqueueJobInput(
                            jobType = SuccessJob.type,
                            targetType = "test",
                            targetId = UUID.randomUUID(),
                            availableAt = Instant.now().plusSeconds(60)
                        )
                    )
                }
            }.getOrNull()!!

            // Act: lease
            val leased = context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = "test-worker", limit = 10) }
            }.getOrNull()!!

            // Assert: only the available job is leased
            leased.size shouldBe 1
            leased[0].id shouldBe availableId

            // Verify future job is still pending
            JobsDb.withConnection { conn ->
                val futureJob = JobsDb.fetchJob(conn, futureId)!!
                futureJob.status shouldBe "pending"
            }
        }
    }
}
