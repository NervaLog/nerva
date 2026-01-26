package dev.dailywombat.jobs.runtime.processor

import arrow.core.raise.either
import dev.dailywombat.jobs.runtime.JobMetrics
import dev.dailywombat.jobs.runtime.actions.ReleaseStaleJobs
import dev.dailywombat.postgrest.PostgRestClient
import io.github.oshai.kotlinlogging.KotlinLogging
import kotlinx.coroutines.*
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

private val logger = KotlinLogging.logger {}

/**
 * Background task that periodically releases stale jobs.
 *
 * Jobs become "stale" when a worker crashes or times out while processing them.
 * They're stuck in 'processing' status with an expired lease. This task finds
 * those jobs and releases them back to the queue for other workers.
 *
 * @param postgRestClient Client for database access
 * @param interval How often to check for stale jobs (default: 30 seconds)
 * @param limit Maximum stale jobs to release per run (default: 100)
 * @param scope Coroutine scope for the background task
 */
class StaleJobRecovery(
    private val postgRestClient: PostgRestClient,
    private val interval: Duration = 30.seconds,
    private val limit: Int = 100,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) : AutoCloseable {

    private var job: Job? = null

    /**
     * Start the background recovery task.
     */
    fun start() {
        if (job != null) {
            logger.warn { "StaleJobRecovery already running" }
            return
        }

        job = scope.launch {
            logger.info { "StaleJobRecovery started (interval=${interval}, limit=$limit)" }

            while (isActive) {
                try {
                    val released = releaseStaleJobs()
                    if (released > 0) {
                        logger.info { "Released $released stale job(s)" }
                        JobMetrics.recovered.increment(released.toDouble())
                    }
                } catch (e: Exception) {
                    logger.error(e) { "Error releasing stale jobs" }
                }

                delay(interval)
            }
        }
    }

    /**
     * Stop the background recovery task.
     */
    fun stop() {
        job?.cancel()
        job = null
        logger.info { "StaleJobRecovery stopped" }
    }

    override fun close() {
        stop()
        scope.cancel()
    }

    private fun releaseStaleJobs(): Int {
        return context(postgRestClient) {
            either { ReleaseStaleJobs(limit) }
                .fold(
                    ifLeft = { error ->
                        logger.error { "Failed to release stale jobs: $error" }
                        0
                    },
                    ifRight = { it }
                )
        }
    }
}
