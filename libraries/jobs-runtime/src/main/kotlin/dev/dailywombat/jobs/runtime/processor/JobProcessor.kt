package dev.dailywombat.jobs.runtime.processor

import arrow.core.raise.Raise
import com.fasterxml.jackson.databind.ObjectMapper
import dev.dailywombat.jobs.runtime.JobMetrics
import dev.dailywombat.jobs.runtime.JobRegistry
import dev.dailywombat.jobs.runtime.actions.LeaseJobs
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import io.github.oshai.kotlinlogging.KotlinLogging
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeoutOrNull
import org.http4k.format.Jackson
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes

private val logger = KotlinLogging.logger {}

/**
 * Processes jobs from the queue using discovered handlers.
 *
 * Supports graceful shutdown: call [shutdown] to stop accepting new work
 * and wait for in-flight jobs to complete.
 *
 * @param registry Source of job handlers (defaults to classpath-discovered)
 * @param mapper Jackson mapper for deserializing job params
 * @param workerId Unique identifier for this worker instance
 * @param batchSize Number of jobs to lease per poll
 * @param concurrency Max concurrent job executions (defaults to batchSize)
 * @param maxAttempts Max retry attempts before marking failed
 * @param backoffSeconds Base backoff for retries (exponential: base * 2^attempts)
 */
class JobProcessor(
    private val registry: JobRegistry = JobRegistry,
    private val mapper: ObjectMapper = Jackson.mapper,
    private val workerId: String = generateWorkerId(),
    private val batchSize: Int = 10,
    private val concurrency: Int = batchSize,
    private val maxAttempts: Int = 3,
    private val backoffSeconds: Int = 30,
) {
    private val semaphore = Semaphore(concurrency)
    private val shutdownRequested = AtomicBoolean(false)
    private val batchInProgress = Mutex()
    private val executor = JobExecutor(registry, mapper, workerId, maxAttempts, backoffSeconds)

    val isShuttingDown: Boolean get() = shutdownRequested.get()

    fun shouldContinue(): Boolean = !shutdownRequested.get()

    context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
    suspend fun processBatch(): Int {
        if (shutdownRequested.get()) return 0

        return batchInProgress.withLock {
            if (shutdownRequested.get()) return@withLock 0

            val jobs = LeaseJobs(workerId, limit = batchSize)
            if (jobs.isEmpty()) return@withLock 0

            logger.debug { "Leased ${jobs.size} jobs" }
            jobs.groupingBy { it.jobType }.eachCount().forEach { (jobType, count) ->
                JobMetrics.leased(jobType).increment(count.toDouble())
            }

            coroutineScope {
                for (job in jobs) {
                    launch {
                        semaphore.withPermit {
                            executor.executeSafely(job, pgRest)
                        }
                    }
                }
            }
            jobs.size
        }
    }

    context(_: PostgRestClient, _: Raise<PostgRestError>)
    suspend fun drainQueue(): Int {
        var total = 0
        while (shouldContinue()) {
            val processed = processBatch()
            if (processed == 0) break
            total += processed
        }
        if (total > 0) logger.info { "Drained $total jobs" }
        return total
    }

    suspend fun shutdown(timeout: Duration = 2.minutes): Boolean {
        if (shutdownRequested.getAndSet(true)) {
            logger.debug { "Shutdown already in progress" }
        } else {
            logger.info { "Shutdown requested for worker $workerId, waiting for in-flight jobs..." }
        }

        val completed = withTimeoutOrNull(timeout) {
            batchInProgress.withLock { }
            true
        } != null

        if (completed) logger.info { "Shutdown complete for worker $workerId" }
        else logger.warn { "Shutdown timed out for worker $workerId after $timeout" }

        return completed
    }

    fun requestShutdown() {
        if (shutdownRequested.getAndSet(true)) return
        logger.info { "Shutdown requested for worker $workerId" }
    }

    companion object {
        private fun generateWorkerId(): String {
            val hostname = try {
                java.net.InetAddress.getLocalHost().hostName
            } catch (_: Exception) {
                "unknown"
            }
            val pid = ProcessHandle.current().pid()
            val ts = System.currentTimeMillis()
            return "$hostname-$pid-$ts"
        }
    }
}
