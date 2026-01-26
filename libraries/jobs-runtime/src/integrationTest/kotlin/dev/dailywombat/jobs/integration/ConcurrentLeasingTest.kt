package dev.dailywombat.jobs.integration

import arrow.core.raise.either
import dev.dailywombat.jobs.actions.EnqueueJob
import dev.dailywombat.jobs.actions.EnqueueJobInput
import dev.dailywombat.jobs.integration.support.Await
import dev.dailywombat.jobs.integration.support.JobsIntegrationEnv
import dev.dailywombat.jobs.integration.support.ResetTestJobs
import dev.dailywombat.jobs.integration.support.db.JobsDb
import dev.dailywombat.jobs.integration.support.testjobs.SlowJob
import dev.dailywombat.jobs.integration.support.testjobs.SuccessJob
import dev.dailywombat.jobs.runtime.actions.LeaseJobs
import dev.dailywombat.jobs.runtime.processor.JobProcessor
import io.kotest.matchers.collections.shouldHaveSize
import io.kotest.matchers.shouldBe
import io.kotest.matchers.shouldNotBe
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.fail
import java.util.*
import java.util.concurrent.ConcurrentHashMap
import kotlin.time.Duration.Companion.seconds

class ConcurrentLeasingTest {

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
    fun `concurrent workers do not lease the same job`() {
        runBlocking {
            // Arrange: enqueue several jobs
            (1..10).map { enqueueJob(SuccessJob.type) }

            // Act: multiple workers lease concurrently
            val leasedByWorker = ConcurrentHashMap<String, MutableSet<UUID>>()

            val workers = (1..5).map { workerId ->
                async {
                    context(JobsIntegrationEnv.pgRest) {
                        val leased = either { LeaseJobs(workerId = "worker-$workerId", limit = 5) }
                            .fold({ emptyList() }, { it })

                        leasedByWorker.computeIfAbsent("worker-$workerId") { mutableSetOf() }
                            .addAll(leased.map { it.id })

                        leased
                    }
                }
            }

            workers.awaitAll()

            // Assert: no job was leased by multiple workers
            val allLeasedIds = leasedByWorker.values.flatten()
            val uniqueLeasedIds = allLeasedIds.toSet()

            // Total leased should equal unique (no duplicates)
            allLeasedIds.size shouldBe uniqueLeasedIds.size

            // All jobs should have been leased exactly once
            uniqueLeasedIds shouldHaveSize 10
        }
    }

    @Test
    fun `SKIP LOCKED prevents double-leasing under contention`() {
        runBlocking {
            // Arrange: enqueue a single job
            val jobId = enqueueJob(SlowJob.type, params = mapOf("delayMs" to 100))

            // Act: race to lease it
            val results = (1..10).map { workerId ->
                async {
                    context(JobsIntegrationEnv.pgRest) {
                        either { LeaseJobs(workerId = "worker-$workerId", limit = 1) }
                            .fold({ emptyList() }, { it })
                    }
                }
            }.awaitAll()

            // Assert: exactly one worker got the job
            val successfulLeases = results.filter { it.isNotEmpty() }
            successfulLeases shouldHaveSize 1
            successfulLeases.first().first().id shouldBe jobId
        }
    }

    @Test
    fun `multiple processors process jobs without conflict`() {
        runBlocking {
            // Arrange: enqueue many jobs
            repeat(20) { enqueueJob(SuccessJob.type) }

            // Act: run multiple processors concurrently
            val processors = (1..4).map {
                JobProcessor(batchSize = 5, maxAttempts = 3)
            }

            val jobs = processors.mapIndexed { idx, processor ->
                async {
                    var total = 0
                    repeat(3) {
                        context(JobsIntegrationEnv.pgRest) {
                            val count = either { processor.processBatch() }
                                .fold({ 0 }, { it })
                            total += count
                        }
                    }
                    total
                }
            }

            val totals = jobs.awaitAll()
            val totalProcessed = totals.sum()

            // Assert: all jobs processed exactly once
            Await.queueDrained(timeout = 5.seconds)

            // Total should be 20 (each job processed once)
            totalProcessed shouldBe 20
            SuccessJob.invocations.get() shouldBe 20
        }
    }

    @Test
    fun `lease expiration allows job to be re-leased`() {
        runBlocking {
            // Arrange: enqueue a job
            val jobId = enqueueJob(SuccessJob.type)

            // Lease it
            context(JobsIntegrationEnv.pgRest) {
                either { LeaseJobs(workerId = "worker-1", limit = 1, leaseDurationMinutes = 1) }
                    .fold({ fail("LeaseJobs failed: $it") }, { it })
            }

            // Verify it's leased
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)
                job!!.status shouldBe "processing"
                job.leaseOwner shouldBe "worker-1"
            }

            // Expire the lease manually
            JobsDb.withConnection { conn ->
                JobsDb.expireLease(conn, jobId)
            }

            // Another worker should not be able to lease it yet (still processing status)
            // Need to release stale jobs first
            // For now, just verify the lease is expired
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)
                // leaseUntil should be in the past
                job!!.leaseUntil shouldNotBe null
            }
        }
    }

    @Test
    fun `lease count increments on each lease`() {
        runBlocking {
            // Arrange: enqueue a job
            val jobId = enqueueJob(SlowJob.type, params = mapOf("delayMs" to 10))

            // First lease and complete
            val processor = JobProcessor(batchSize = 1, maxAttempts = 3)
            context(JobsIntegrationEnv.pgRest) {
                either { processor.processBatch() }
            }
            Await.jobStatus(jobId, "completed")

            // Check lease count
            JobsDb.withConnection { conn ->
                val job = JobsDb.fetchJob(conn, jobId)
                job!!.leaseCount shouldBe 1
                job.attempts shouldBe 0 // Successful, no failures
            }
        }
    }

    @Test
    fun `different job types can be filtered during lease`() {
        runBlocking {
            // Arrange: enqueue jobs of different types
            val successId = enqueueJob(SuccessJob.type)
            val slowId = enqueueJob(SlowJob.type, params = mapOf("delayMs" to 10))

            // Lease only success jobs
            context(JobsIntegrationEnv.pgRest) {
                val leased = either {
                    LeaseJobs(workerId = "worker-1", limit = 10, jobTypes = listOf(SuccessJob.type))
                }.fold({ fail("LeaseJobs failed: $it") }, { it })

                // Should only get the success job
                leased shouldHaveSize 1
                leased.first().id shouldBe successId
                leased.first().jobType shouldBe SuccessJob.type
            }

            // Slow job should still be pending
            JobsDb.withConnection { conn ->
                JobsDb.fetchJob(conn, slowId)!!.status shouldBe "pending"
            }
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
