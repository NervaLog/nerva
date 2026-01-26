package dev.dailywombat.jobs.integration

import arrow.core.raise.either
import dev.dailywombat.jobs.actions.EnqueueJob
import dev.dailywombat.jobs.actions.EnqueueJobInput
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
import java.util.*

/**
 * Tests that jobs are leased in priority order.
 *
 * Priority ordering: higher priority values are leased first.
 * Tie-break: earlier available_at, then job id.
 */
class PriorityOrderingIT {

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
    fun `high priority job is leased before low priority job`() {
        runBlocking {
            // Arrange: enqueue low priority first, then high priority
            val lowPriorityId = enqueueJob(priority = 0)
            val highPriorityId = enqueueJob(priority = 10)

            // Act: lease only 1 job
            val leased = context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = "test-worker", limit = 1) }
            }.getOrNull()!!

            // Assert: high priority job should be leased first
            leased.size shouldBe 1
            leased[0].id shouldBe highPriorityId

            // Verify low priority job is still pending
            JobsDb.withConnection { conn ->
                val lowJob = JobsDb.fetchJob(conn, lowPriorityId)!!
                lowJob.status shouldBe "pending"
            }
        }
    }

    @Test
    fun `same priority jobs are leased by available_at order`() {
        runBlocking {
            // Arrange: enqueue two jobs with same priority
            // First job gets earlier available_at by being inserted first
            val firstId = enqueueJob(priority = 5)
            Thread.sleep(10) // Ensure different timestamps
            enqueueJob(priority = 5)

            // Act: lease only 1 job
            val leased = context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = "test-worker", limit = 1) }
            }.getOrNull()!!

            // Assert: first job (earlier available_at) should be leased first
            leased.size shouldBe 1
            leased[0].id shouldBe firstId
        }
    }

    @Test
    fun `multiple priorities are correctly ordered`() {
        runBlocking {
            // Arrange: enqueue jobs with various priorities in random order
            val lowId = enqueueJob(priority = 1)
            val highId = enqueueJob(priority = 100)
            val mediumId = enqueueJob(priority = 50)
            val lowestId = enqueueJob(priority = 0)

            // Act: lease all jobs
            val leased = context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = "test-worker", limit = 10) }
            }.getOrNull()!!

            // Assert: should be ordered by priority descending
            leased.size shouldBe 4
            leased.map { it.id } shouldBe listOf(highId, mediumId, lowId, lowestId)
        }
    }

    private fun enqueueJob(priority: Int): UUID {
        return context(JobsIntegrationEnv.pgRest) {
            either {
                EnqueueJob(
                    EnqueueJobInput(
                        jobType = SuccessJob.type,
                        targetType = "test",
                        targetId = UUID.randomUUID(),
                        priority = priority
                    )
                )
            }
        }.getOrNull() ?: throw AssertionError("Failed to enqueue job\n${JobsIntegrationEnv.dumpState()}")
    }
}
