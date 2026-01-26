package dev.dailywombat.jobs.integration

import arrow.core.raise.either
import dev.dailywombat.jobs.actions.EnqueueJob
import dev.dailywombat.jobs.actions.EnqueueJobInput
import dev.dailywombat.jobs.integration.support.JobsIntegrationEnv
import dev.dailywombat.jobs.integration.support.ResetTestJobs
import dev.dailywombat.jobs.integration.support.db.JobsDb
import dev.dailywombat.jobs.integration.support.testjobs.SuccessJob
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
 * Tests idempotency key race condition handling.
 *
 * When multiple concurrent requests try to enqueue a job with the same
 * idempotency key, exactly one job should be created and all callers
 * should receive the same job ID.
 */
class EnqueueIdempotencyRaceIT {

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
    fun `concurrent enqueues with same idempotency key return same job ID`() {
        runBlocking {
            // Arrange
            val idempotencyKey = "same-key-${UUID.randomUUID()}"
            val targetId = UUID.randomUUID()
            val input = EnqueueJobInput(
                jobType = SuccessJob.type,
                targetType = "test",
                targetId = targetId,
                idempotencyKey = idempotencyKey
            )

            // Act: launch N=25 concurrent enqueue calls
            val n = 25
            val jobIds = (1..n).map {
                async(Dispatchers.IO) {
                    context(JobsIntegrationEnv.pgRest) {
                        either { EnqueueJob(input) }
                    }.getOrNull()
                }
            }.awaitAll()

            // Assert: all returned IDs should be non-null and equal
            val nonNullIds = jobIds.filterNotNull()
            nonNullIds.size shouldBe n

            val uniqueIds = nonNullIds.toSet()
            uniqueIds.size shouldBe 1

            // Assert: exactly one job exists in database
            JobsDb.withConnection { conn ->
                val count = JobsDb.countJobsWithIdempotencyKey(conn, SuccessJob.type, idempotencyKey)
                count shouldBe 1
            }
        }
    }

    @Test
    fun `different idempotency keys create separate jobs`() {
        runBlocking {
            // Arrange
            val targetId = UUID.randomUUID()

            // Act: enqueue jobs with different idempotency keys
            val id1 = enqueueWithKey("key-1", targetId)
            val id2 = enqueueWithKey("key-2", targetId)
            val id3 = enqueueWithKey("key-3", targetId)

            // Assert: all IDs should be different
            val ids = setOf(id1, id2, id3)
            ids.size shouldBe 3

            // Assert: three jobs exist
            JobsDb.withConnection { conn ->
                val jobs = JobsDb.fetchAllJobs(conn)
                jobs.size shouldBe 3
            }
        }
    }

    @Test
    fun `same idempotency key with different job types creates separate jobs`() {
        runBlocking {
            // Arrange
            val idempotencyKey = "shared-key"
            val targetId = UUID.randomUUID()

            // Act: enqueue with same key but different job types
            val id1 = context(JobsIntegrationEnv.pgRest) {
                either {
                    EnqueueJob(
                        EnqueueJobInput(
                            jobType = SuccessJob.type,
                            targetType = "test",
                            targetId = targetId,
                            idempotencyKey = idempotencyKey
                        )
                    )
                }
            }.getOrNull()!!

            val id2 = context(JobsIntegrationEnv.pgRest) {
                either {
                    EnqueueJob(
                        EnqueueJobInput(
                            jobType = "different_job_type",
                            targetType = "test",
                            targetId = targetId,
                            idempotencyKey = idempotencyKey
                        )
                    )
                }
            }.getOrNull()!!

            // Assert: different jobs created (idempotency is scoped to job_type)
            id1 shouldNotBe id2
        }
    }

    private fun enqueueWithKey(key: String, targetId: UUID): UUID {
        return context(JobsIntegrationEnv.pgRest) {
            either {
                EnqueueJob(
                    EnqueueJobInput(
                        jobType = SuccessJob.type,
                        targetType = "test",
                        targetId = targetId,
                        idempotencyKey = key
                    )
                )
            }
        }.getOrNull() ?: throw AssertionError("Failed to enqueue job\n${JobsIntegrationEnv.dumpState()}")
    }

    private infix fun Any?.shouldNotBe(other: Any?) {
        if (this == other) {
            throw AssertionError("Expected $this to not equal $other")
        }
    }
}
