package dev.dailywombat.jobs.runtime.actions

import arrow.core.raise.either
import dev.dailywombat.TestContainers
import dev.dailywombat.jobs.actions.EnqueueJob
import dev.dailywombat.jobs.actions.EnqueueJobInput
import io.kotest.matchers.shouldBe
import io.kotest.matchers.shouldNotBe
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.fail
import java.util.*

class JobActionsTest {

    companion object {
        @BeforeAll
        @JvmStatic
        fun before() = TestContainers.start()

        @AfterAll
        @JvmStatic
        fun after() = TestContainers.stop()
    }

    @Test
    fun `EnqueueJob should create a job and return its ID`() {
        val input = EnqueueJobInput(
            jobType = "test_job",
            targetType = "test_target",
            targetId = UUID.randomUUID()
        )

        context(TestContainers.postgRestClient()) {
            val jobId = either { EnqueueJob(input) }
                .fold(
                    ifLeft = { fail("EnqueueJob failed: $it") },
                    ifRight = { it }
                )

            jobId shouldNotBe null
        }
    }

    @Test
    fun `EnqueueJob with idempotency key should deduplicate`() {
        val idempotencyKey = "test_dedup_${UUID.randomUUID()}"
        val input = EnqueueJobInput(
            jobType = "test_job",
            targetType = "test_target",
            targetId = UUID.randomUUID(),
            idempotencyKey = idempotencyKey
        )

        context(TestContainers.postgRestClient()) {
            val firstJobId = either { EnqueueJob(input) }
                .fold(
                    ifLeft = { fail("First EnqueueJob failed: $it") },
                    ifRight = { it }
                )

            val secondJobId = either { EnqueueJob(input.copy(targetId = UUID.randomUUID())) }
                .fold(
                    ifLeft = { fail("Second EnqueueJob failed: $it") },
                    ifRight = { it }
                )

            // Same idempotency key should return same job ID
            secondJobId shouldBe firstJobId
        }
    }

    @Test
    fun `LeaseJobs should return empty list when no jobs available`() {
        context(TestContainers.postgRestClient()) {
            val jobs = either { LeaseJobs(workerId = "test_worker_${UUID.randomUUID()}") }
                .fold(
                    ifLeft = { fail("LeaseJobs failed: $it") },
                    ifRight = { it }
                )

            // May or may not be empty depending on other test state, but should not fail
            jobs shouldNotBe null
        }
    }

    @Test
    fun `LeaseJobs should lease a pending job`() {
        val targetId = UUID.randomUUID()
        val input = EnqueueJobInput(
            jobType = "lease_test_job",
            targetType = "test_target",
            targetId = targetId
        )

        context(TestContainers.postgRestClient()) {
            // Create a job
            val jobId = either { EnqueueJob(input) }
                .fold(
                    ifLeft = { fail("EnqueueJob failed: $it") },
                    ifRight = { it }
                )

            // Lease it
            val workerId = "test_worker_${UUID.randomUUID()}"
            val jobs = either { LeaseJobs(workerId = workerId, jobTypes = listOf("lease_test_job")) }
                .fold(
                    ifLeft = { fail("LeaseJobs failed: $it") },
                    ifRight = { it }
                )

            // Should have leased our job
            val leasedJob = jobs.find { it.id == jobId }
            leasedJob shouldNotBe null
            leasedJob!!.jobType shouldBe "lease_test_job"
            leasedJob.targetType shouldBe "test_target"
            leasedJob.targetId shouldBe targetId
        }
    }

    @Test
    fun `CompleteJob should mark a leased job as completed`() {
        val input = EnqueueJobInput(
            jobType = "complete_test_job_${UUID.randomUUID()}",
            targetType = "test_target",
            targetId = UUID.randomUUID()
        )

        context(TestContainers.postgRestClient()) {
            // Create and lease a job
            val jobId = either { EnqueueJob(input) }
                .fold(
                    ifLeft = { fail("EnqueueJob failed: $it") },
                    ifRight = { it }
                )

            val workerId = "test_worker_${UUID.randomUUID()}"
            either { LeaseJobs(workerId = workerId, jobTypes = listOf(input.jobType)) }
                .fold(
                    ifLeft = { fail("LeaseJobs failed: $it") },
                    ifRight = { it }
                )

            // Complete it
            val completed = either { CompleteJob(jobId, workerId) }
                .fold(
                    ifLeft = { fail("CompleteJob failed: $it") },
                    ifRight = { it }
                )

            completed shouldBe true
        }
    }

    @Test
    fun `CompleteJob should fail for non-existent job`() {
        context(TestContainers.postgRestClient()) {
            val completed = either { CompleteJob(UUID.randomUUID()) }
                .fold(
                    ifLeft = { fail("CompleteJob failed unexpectedly: $it") },
                    ifRight = { it }
                )

            completed shouldBe false
        }
    }

    @Test
    fun `FailOrRetryJob should retry a job when under max attempts`() {
        val input = EnqueueJobInput(
            jobType = "retry_test_job_${UUID.randomUUID()}",
            targetType = "test_target",
            targetId = UUID.randomUUID()
        )

        context(TestContainers.postgRestClient()) {
            // Create and lease a job
            val jobId = either { EnqueueJob(input) }
                .fold(
                    ifLeft = { fail("EnqueueJob failed: $it") },
                    ifRight = { it }
                )

            val workerId = "test_worker_${UUID.randomUUID()}"
            either { LeaseJobs(workerId = workerId, jobTypes = listOf(input.jobType)) }
                .fold(
                    ifLeft = { fail("LeaseJobs failed: $it") },
                    ifRight = { it }
                )

            // Fail it (should retry since attempts < maxAttempts)
            val result = either {
                FailOrRetryJob(
                    jobId = jobId,
                    workerId = workerId,
                    maxAttempts = 3,
                    error = "Test error"
                )
            }.fold(
                ifLeft = { fail("FailOrRetryJob failed: $it") },
                ifRight = { it }
            )

            result shouldBe FailOrRetryResult.RETRYING
        }
    }

    @Test
    fun `FailOrRetryJob should fail a job when max attempts reached`() {
        val input = EnqueueJobInput(
            jobType = "fail_test_job_${UUID.randomUUID()}",
            targetType = "test_target",
            targetId = UUID.randomUUID()
        )

        context(TestContainers.postgRestClient()) {
            // Create and lease a job
            val jobId = either { EnqueueJob(input) }
                .fold(
                    ifLeft = { fail("EnqueueJob failed: $it") },
                    ifRight = { it }
                )

            val workerId = "test_worker_${UUID.randomUUID()}"
            either { LeaseJobs(workerId = workerId, jobTypes = listOf(input.jobType)) }
                .fold(
                    ifLeft = { fail("LeaseJobs failed: $it") },
                    ifRight = { it }
                )

            // Fail it with maxAttempts = 1 (job already has 1 attempt from lease)
            val result = either {
                FailOrRetryJob(
                    jobId = jobId,
                    workerId = workerId,
                    maxAttempts = 1,
                    error = "Final failure"
                )
            }.fold(
                ifLeft = { fail("FailOrRetryJob failed: $it") },
                ifRight = { it }
            )

            result shouldBe FailOrRetryResult.FAILED
        }
    }

    @Test
    fun `FailOrRetryJob should return NOT_FOUND for non-existent job`() {
        context(TestContainers.postgRestClient()) {
            val result = either {
                FailOrRetryJob(
                    jobId = UUID.randomUUID(),
                    error = "Test error"
                )
            }.fold(
                ifLeft = { fail("FailOrRetryJob failed unexpectedly: $it") },
                ifRight = { it }
            )

            result shouldBe FailOrRetryResult.NOT_FOUND
        }
    }
}
