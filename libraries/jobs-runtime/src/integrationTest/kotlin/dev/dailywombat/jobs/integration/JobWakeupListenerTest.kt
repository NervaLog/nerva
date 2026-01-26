package dev.dailywombat.jobs.integration

import arrow.core.raise.either
import com.impossibl.postgres.api.jdbc.PGConnection
import com.impossibl.postgres.jdbc.PGDataSource
import dev.dailywombat.PostgresContainer
import dev.dailywombat.jobs.actions.EnqueueJob
import dev.dailywombat.jobs.actions.EnqueueJobInput
import dev.dailywombat.jobs.integration.support.Await
import dev.dailywombat.jobs.integration.support.JobsIntegrationEnv
import dev.dailywombat.jobs.integration.support.ResetTestJobs
import dev.dailywombat.jobs.integration.support.testjobs.SuccessJob
import dev.dailywombat.jobs.runtime.listener.wakeup.JobWakeupListener
import dev.dailywombat.jobs.runtime.processor.JobProcessor
import io.kotest.matchers.shouldBe
import kotlinx.coroutines.*
import org.junit.jupiter.api.*
import java.util.*
import java.util.concurrent.atomic.AtomicInteger
import kotlin.time.Duration.Companion.seconds

class JobWakeupListenerTest {

    companion object {
        @BeforeAll
        @JvmStatic
        fun beforeAll() = JobsIntegrationEnv.start()

        // Don't stop containers - let Ryuk handle cleanup
        // Stopping between test classes breaks container restart
    }

    private val testScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var listener: JobWakeupListener? = null

    @BeforeEach
    fun beforeEach() {
        JobsIntegrationEnv.resetJobs()
        ResetTestJobs()
    }

    @AfterEach
    fun afterEach() {
        listener?.close()
        listener = null
    }

    private fun createConnectionSource(): () -> PGConnection = {
        val ds = PGDataSource().apply {
            serverName = "localhost"
            port = PostgresContainer.Container.getMappedPort(PostgresContainer.Port)
            databaseName = PostgresContainer.Db
            user = PostgresContainer.Username
            password = PostgresContainer.Password
        }
        ds.connection as PGConnection
    }

    @Test
    fun `listener invokes onWake when job is enqueued`() {
        runBlocking {
            val wakeCount = AtomicInteger(0)

            listener = JobWakeupListener(
                connectionSource = createConnectionSource(),
                onWake = { wakeCount.incrementAndGet() },
                scope = testScope
            )
            listener!!.start()

            // Wait for listener to connect
            delay(500)

            // Enqueue a job - should trigger notification
            enqueueJob(SuccessJob.type)

            // Wait for wake callback
            Await.condition(timeout = 3.seconds, description = "onWake callback") {
                wakeCount.get() > 0
            }

            wakeCount.get() shouldBe 1
        }
    }

    @Test
    fun `listener processes job when woken up`() {
        runBlocking {
            val processor = JobProcessor(batchSize = 10, maxAttempts = 3)
            var processed = 0

            listener = JobWakeupListener(
                connectionSource = createConnectionSource(),
                onWake = {
                    context(JobsIntegrationEnv.pgRest) {
                        val count = either { processor.processBatch() }
                            .fold({ 0 }, { it })
                        processed += count
                    }
                },
                scope = testScope
            )
            listener!!.start()

            // Wait for listener to connect
            delay(500)

            // Enqueue a job - listener should wake up and process it
            val jobId = enqueueJob(SuccessJob.type)

            // Wait for processing
            Await.condition(timeout = 5.seconds, description = "job processed") {
                processed > 0
            }

            processed shouldBe 1
            SuccessJob.invocations.get() shouldBe 1
            Await.jobStatus(jobId, "completed")
        }
    }

    @Test
    fun `listener handles multiple rapid notifications`() {
        runBlocking {
            val wakeCount = AtomicInteger(0)
            val processor = JobProcessor(batchSize = 10, maxAttempts = 3)

            listener = JobWakeupListener(
                connectionSource = createConnectionSource(),
                onWake = {
                    wakeCount.incrementAndGet()
                    context(JobsIntegrationEnv.pgRest) {
                        either { processor.processBatch() }
                    }
                },
                scope = testScope
            )
            listener!!.start()

            // Wait for listener to connect
            delay(500)

            // Enqueue multiple jobs rapidly
            repeat(5) {
                enqueueJob(SuccessJob.type)
            }

            // Wait for all jobs to be processed
            Await.condition(timeout = 5.seconds, description = "all jobs completed") {
                SuccessJob.invocations.get() >= 5
            }

            SuccessJob.invocations.get() shouldBe 5
            // Due to CONFLATED channel, may have fewer wake calls than jobs
            (wakeCount.get() >= 1) shouldBe true
        }
    }

    @Test
    fun `listener reconnects after close and start`() {
        runBlocking {
            val wakeCount = AtomicInteger(0)

            listener = JobWakeupListener(
                connectionSource = createConnectionSource(),
                onWake = { wakeCount.incrementAndGet() },
                scope = testScope
            )

            // Start, close, create new, start again
            listener!!.start()
            delay(300)
            listener!!.close()
            delay(100)

            // Create new listener (old one is closed)
            listener = JobWakeupListener(
                connectionSource = createConnectionSource(),
                onWake = { wakeCount.incrementAndGet() },
                scope = testScope
            )
            listener!!.start()
            delay(500)

            // Should still receive notifications
            enqueueJob(SuccessJob.type)

            Await.condition(timeout = 3.seconds, description = "onWake after reconnect") {
                wakeCount.get() > 0
            }

            (wakeCount.get() >= 1) shouldBe true
        }
    }

    // Helper to enqueue a job
    private fun enqueueJob(
        jobType: String,
        targetType: String = "test",
        targetId: UUID = UUID.randomUUID()
    ): UUID {
        return context(JobsIntegrationEnv.pgRest) {
            either {
                EnqueueJob(
                    EnqueueJobInput(
                        jobType = jobType,
                        targetType = targetType,
                        targetId = targetId
                    )
                )
            }.fold(
                { fail("EnqueueJob failed: $it") },
                { it }
            )
        }
    }
}
