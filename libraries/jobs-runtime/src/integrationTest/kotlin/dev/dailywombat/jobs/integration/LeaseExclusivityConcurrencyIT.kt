package dev.dailywombat.jobs.integration

import arrow.core.raise.either
import dev.dailywombat.jobs.actions.EnqueueJob
import dev.dailywombat.jobs.actions.EnqueueJobInput
import dev.dailywombat.jobs.integration.support.JobsIntegrationEnv
import dev.dailywombat.jobs.integration.support.ResetTestJobs
import dev.dailywombat.jobs.integration.support.db.JobsDb
import dev.dailywombat.jobs.integration.support.testjobs.SuccessJob
import dev.dailywombat.jobs.runtime.actions.LeaseJobs
import dev.dailywombat.jobs.runtime.actions.LeasedJob
import io.kotest.matchers.shouldBe
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import java.util.*

/**
 * Tests concurrent lease exclusivity using SKIP LOCKED.
 *
 * When multiple workers attempt to lease jobs concurrently,
 * each job should be leased by exactly one worker.
 */
class LeaseExclusivityConcurrencyIT {

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
    fun `concurrent workers do not lease the same job`() {
        runBlocking {
            // Arrange: enqueue 200 jobs with unique targetId
            val jobCount = 200
            repeat(jobCount) {
                enqueueJob()
            }

            // Act: run M=10 concurrent LeaseJobs calls
            val workerCount = 10
            val limitPerWorker = 25

            val allLeased: List<List<LeasedJob>> = (1..workerCount).map { workerId ->
                async(Dispatchers.IO) {
                    context(JobsIntegrationEnv.pgRest) {
                        either {
                            LeaseJobs(
                                workerId = "worker-$workerId",
                                limit = limitPerWorker,
                                leaseDurationMinutes = 5
                            )
                        }
                    }.getOrNull() ?: emptyList()
                }
            }.awaitAll()

            // Collect all leased job IDs
            val allLeasedIds = allLeased.flatten().map { it.id }

            // Assert: no duplicates (each job leased by exactly one worker)
            allLeasedIds.size shouldBe allLeasedIds.distinct().size

            // Assert: total leased should be min(200, 10*25) = 200
            val expectedTotal = minOf(jobCount, workerCount * limitPerWorker)
            allLeasedIds.size shouldBe expectedTotal

            // Assert: all leased jobs have correct status
            JobsDb.withConnection { conn ->
                for (jobId in allLeasedIds) {
                    val job = JobsDb.fetchJob(conn, jobId)
                        ?: throw AssertionError("Job $jobId not found\n${JobsIntegrationEnv.dumpState()}")
                    job.status shouldBe "processing"
                    job.leaseOwner shouldNotBeNull "Job $jobId should have lease_owner"
                    job.leaseUntil shouldNotBeNull "Job $jobId should have lease_until"
                }
            }
        }
    }

    @Test
    fun `workers with higher limit than available jobs get all jobs`() {
        runBlocking {
            // Arrange: enqueue only 5 jobs
            val jobCount = 5
            repeat(jobCount) {
                enqueueJob()
            }

            // Act: 3 workers each try to lease 10 jobs
            val workerCount = 3
            val limitPerWorker = 10

            val allLeased: List<List<LeasedJob>> = (1..workerCount).map { workerId ->
                async(Dispatchers.IO) {
                    context(JobsIntegrationEnv.pgRest) {
                        either {
                            LeaseJobs(
                                workerId = "worker-$workerId",
                                limit = limitPerWorker,
                                leaseDurationMinutes = 5
                            )
                        }
                    }.getOrNull() ?: emptyList()
                }
            }.awaitAll()

            // Collect all leased job IDs
            val allLeasedIds = allLeased.flatten().map { it.id }

            // Assert: all 5 jobs should be leased, no duplicates
            allLeasedIds.size shouldBe jobCount
            allLeasedIds.distinct().size shouldBe jobCount
        }
    }

    @Test
    fun `lease records worker identity`() {
        runBlocking {
            // Arrange
            enqueueJob()

            // Act
            val workerId = "specific-worker-123"
            val leased = context(JobsIntegrationEnv.pgRest) {
                either {
                    LeaseJobs(workerId = workerId, limit = 1)
                }
            }.getOrNull()!!

            // Assert
            leased.size shouldBe 1
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, leased[0].id)!!
                job.leaseOwner shouldBe workerId
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

    private infix fun <T> T?.shouldNotBeNull(message: String) {
        if (this == null) {
            throw AssertionError("$message\n${JobsIntegrationEnv.dumpState()}")
        }
    }
}
