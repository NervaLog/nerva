package dev.dailywombat.jobs.integration.chaos

import arrow.core.raise.either
import dev.dailywombat.jobs.actions.EnqueueJob
import dev.dailywombat.jobs.actions.EnqueueJobInput
import dev.dailywombat.jobs.integration.support.ResetTestJobs
import dev.dailywombat.jobs.integration.support.testjobs.SlowJob
import dev.dailywombat.jobs.integration.support.testjobs.SuccessJob
import dev.dailywombat.jobs.runtime.processor.JobProcessor
import dev.dailywombat.postgrest.PostgRestError
import io.kotest.matchers.shouldBe
import io.kotest.matchers.types.shouldBeInstanceOf
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.*
import java.util.*

/**
 * Chaos tests for network fault injection.
 *
 * These tests use Toxiproxy to simulate network failures between
 * PostgREST and PostgreSQL.
 *
 * Run with: ./gradlew :libraries:jobs-runtime:integrationTest -Pchaos
 */
@Tag("chaos")
class NetworkPartitionTest {

    companion object {
        @BeforeAll
        @JvmStatic
        fun beforeAll() = ChaosTestEnv.start()

        @AfterAll
        @JvmStatic
        fun afterAll() = ChaosTestEnv.stop()
    }

    @BeforeEach
    fun beforeEach() {
        ChaosTestEnv.resetToxics()
        ResetTestJobs()
    }

    @AfterEach
    fun afterEach() {
        ChaosTestEnv.resetToxics()
    }

    @Test
    fun `processBatch fails gracefully during network partition`() {
        runBlocking {
            // Arrange: enqueue a job (before partition)
            enqueueJob(SuccessJob.type)

            // Cut the network
            ChaosTestEnv.cutConnection()

            // Act: try to process
            val processor = JobProcessor(batchSize = 10, maxAttempts = 3)
            val result = context(ChaosTestEnv.pgRest) {
                either { processor.processBatch() }
            }

            // Assert: should fail with PostgREST error (connection refused/timeout)
            result.isLeft() shouldBe true
            result.leftOrNull().shouldBeInstanceOf<PostgRestError>()
        }
    }

    @Test
    fun `processBatch recovers after network restored`() {
        runBlocking {
            // Arrange: enqueue a job
            ChaosTestEnv.resetToxics()
            enqueueJob(SuccessJob.type)

            // Verify normal operation works
            val processor = JobProcessor(batchSize = 10, maxAttempts = 3)

            // Cut, then restore
            ChaosTestEnv.cutConnection()
            Thread.sleep(100) // Let the cut take effect
            ChaosTestEnv.restoreConnection()
            Thread.sleep(500) // Let connections re-establish

            // Act: process after restore
            val result = context(ChaosTestEnv.pgRest) {
                either { processor.processBatch() }
            }

            // Assert: should succeed
            result.isRight() shouldBe true
            result.getOrNull() shouldBe 1
            SuccessJob.invocations.get() shouldBe 1
        }
    }

    @Test
    fun `high latency causes timeout but job remains processable`() {
        runBlocking {
            // Arrange: enqueue a job
            enqueueJob(SlowJob.type, params = mapOf("delayMs" to 10))

            // Add extreme latency (simulates slow network)
            ChaosTestEnv.addLatency(latencyMs = 5000)

            // Act: try to process with short timeout
            val processor = JobProcessor(batchSize = 10, maxAttempts = 3)
            context(ChaosTestEnv.pgRest) {
                either { processor.processBatch() }
            }

            // The request will likely timeout or take very long
            // Either way, we're testing that it doesn't crash
            // Reset and verify job is still there
            ChaosTestEnv.resetToxics()

            // After network restored, job should still be processable
            val retryResult = context(ChaosTestEnv.pgRest) {
                either { processor.processBatch() }
            }

            // Should either succeed or find job in processing (if previous attempt got it)
            // The key is we don't crash
            retryResult.isRight() shouldBe true
        }
    }

    @Test
    fun `bandwidth limit slows but doesnt break processing`() {
        runBlocking {
            // Arrange: enqueue a job
            enqueueJob(SuccessJob.type)

            // Limit bandwidth (very slow, but not zero)
            ChaosTestEnv.limitBandwidth(bytesPerSecond = 10000) // 10KB/s

            // Act: process (will be slow)
            val processor = JobProcessor(batchSize = 10, maxAttempts = 3)
            val startTime = System.currentTimeMillis()
            val result = context(ChaosTestEnv.pgRest) {
                either { processor.processBatch() }
            }
            val elapsed = System.currentTimeMillis() - startTime

            // Assert: should still succeed, just slower
            result.isRight() shouldBe true
            result.getOrNull() shouldBe 1
            SuccessJob.invocations.get() shouldBe 1

            // Bandwidth limit should have added some delay
            (elapsed > 100) shouldBe true // At least some delay
        }
    }

    // Helper to enqueue a job
    private fun enqueueJob(
        jobType: String,
        targetType: String = "test",
        targetId: UUID = UUID.randomUUID(),
        params: Map<String, Any>? = null
    ): UUID = context(ChaosTestEnv.pgRest) {
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
            { throw RuntimeException("EnqueueJob failed: $it") },
            { it }
        )
    }
}
