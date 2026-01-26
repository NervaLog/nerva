package dev.dailywombat.jobs.integration.support

import arrow.core.raise.either
import com.impossibl.postgres.api.jdbc.PGConnection
import com.impossibl.postgres.jdbc.PGDataSource
import dev.dailywombat.PostgresContainer
import dev.dailywombat.jobs.Job
import dev.dailywombat.jobs.runtime.listener.wakeup.JobWakeupListener
import dev.dailywombat.jobs.runtime.processor.JobProcessor
import io.github.oshai.kotlinlogging.KotlinLogging
import kotlinx.coroutines.*
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.Job as CoroutineJob

private val logger = KotlinLogging.logger {}

/**
 * Test worker for E2E integration tests.
 *
 * Wraps JobProcessor and JobWakeupListener to provide a complete worker
 * that can be started, stopped, and monitored.
 *
 * Note: Test job handlers (SuccessJob, FailUntilAttemptJob, etc.) are discovered
 * via classpath scanning, so there's no need to explicitly register them.
 *
 * @param handlers Ignored - kept for API compatibility
 * @param batchSize Number of jobs to process per batch
 * @param maxAttempts Maximum retry attempts before failure
 * @param backoffSeconds Base backoff for retries
 * @param pollTimeoutMs Polling timeout when listener is not active
 */
class TestWorker(
    handlers: List<Job<*>> = emptyList(),
    private val batchSize: Int = 10,
    private val maxAttempts: Int = 3,
    private val backoffSeconds: Int = 1,
    private val pollTimeoutMs: Long = 5000
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // Use the global JobRegistry - test jobs are auto-discovered
    private val processor = JobProcessor(
        batchSize = batchSize,
        maxAttempts = maxAttempts,
        backoffSeconds = backoffSeconds
    )

    private var listener: JobWakeupListener? = null
    private var workerJob: CoroutineJob? = null
    private val running = AtomicBoolean(false)
    private val listenerEnabled = AtomicBoolean(true)

    /** Number of jobs processed by this worker */
    val processedCount = AtomicInteger(0)

    /** Number of batches processed */
    val batchCount = AtomicInteger(0)

    /**
     * Start the worker.
     *
     * Starts both the LISTEN/NOTIFY listener and the processing loop.
     */
    fun start() {
        if (!running.compareAndSet(false, true)) {
            logger.warn { "TestWorker already running" }
            return
        }

        logger.info { "Starting TestWorker" }

        // Create and start listener
        if (listenerEnabled.get()) {
            listener = JobWakeupListener(
                connectionSource = { createPgConnection() },
                onWake = { processAvailableJobs() },
                scope = scope
            )
            listener?.start()
        }

        // Start worker loop
        workerJob = scope.launch {
            workerLoop()
        }

        logger.info { "TestWorker started" }
    }

    /**
     * Stop the worker gracefully.
     *
     * Waits for in-flight jobs to complete.
     */
    suspend fun stop(timeout: Duration = 5.seconds) {
        if (!running.compareAndSet(true, false)) {
            return
        }

        logger.info { "Stopping TestWorker" }

        // Stop accepting new work
        processor.requestShutdown()

        // Stop listener
        listener?.close()
        listener = null

        // Wait for worker loop to finish
        withTimeoutOrNull(timeout) {
            workerJob?.join()
        }

        workerJob?.cancel()
        workerJob = null

        logger.info { "TestWorker stopped (processed ${processedCount.get()} jobs)" }
    }

    /**
     * Stop only the LISTEN/NOTIFY listener.
     *
     * The worker loop continues but relies on polling.
     * Use this for NotifyMissedStillWorksIT.
     */
    fun stopListenerOnly() {
        logger.info { "Stopping TestWorker listener only" }
        listenerEnabled.set(false)
        listener?.close()
        listener = null
    }

    /**
     * Wait for the queue to be drained (no more pending/retrying jobs).
     */
    suspend fun awaitDrained(timeout: Duration = 10.seconds) {
        Await.queueDrained(timeout)
    }

    /**
     * Wait for a specific number of jobs to be processed.
     */
    suspend fun awaitProcessedCount(expected: Int, timeout: Duration = 10.seconds) {
        Await.condition(
            timeout = timeout,
            description = "processed count to reach $expected"
        ) {
            processedCount.get() >= expected
        }
    }

    private suspend fun workerLoop() {
        logger.debug { "Worker loop started" }

        while (running.get() && processor.shouldContinue()) {
            try {
                val processed = processAvailableJobs()

                if (processed == 0) {
                    // No jobs processed, wait before polling again
                    // If listener is active, it will wake us up sooner
                    delay(pollTimeoutMs.milliseconds)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                logger.error(e) { "Error in worker loop" }
                delay(1000.milliseconds) // Back off on error
            }
        }

        logger.debug { "Worker loop exited" }
    }

    private suspend fun processAvailableJobs(): Int {
        if (!running.get()) return 0

        return context(JobsIntegrationEnv.pgRest) {
            either {
                var total = 0
                // Process all available batches
                while (processor.shouldContinue()) {
                    val count = processor.processBatch()
                    if (count == 0) break
                    total += count
                    processedCount.addAndGet(count)
                    batchCount.incrementAndGet()
                }
                total
            }
        }.fold(
            { error ->
                logger.error { "Error processing jobs: $error" }
                0
            },
            { it }
        )
    }

    private fun createPgConnection(): PGConnection {
        val ds = PGDataSource().apply {
            serverName = "localhost"
            port = PostgresContainer.Container.getMappedPort(PostgresContainer.Port)
            databaseName = PostgresContainer.Db
            user = PostgresContainer.Username
            password = PostgresContainer.Password
        }
        return ds.connection as PGConnection
    }
}
