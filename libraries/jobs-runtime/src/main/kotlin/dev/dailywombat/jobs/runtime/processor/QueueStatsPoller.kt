package dev.dailywombat.jobs.runtime.processor

import arrow.core.raise.either
import dev.dailywombat.jobs.runtime.JobMetrics
import dev.dailywombat.jobs.runtime.actions.GetQueueStats
import dev.dailywombat.postgrest.PostgRestClient
import io.github.oshai.kotlinlogging.KotlinLogging
import kotlinx.coroutines.*
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

private val logger = KotlinLogging.logger {}

/**
 * Background task that periodically polls queue statistics and updates metrics gauges.
 *
 * This decouples metric scrape frequency from database load - gauges are updated
 * on a fixed schedule regardless of how often Prometheus scrapes.
 *
 * @param postgRestClient Client for database access
 * @param interval How often to poll stats (default: 15 seconds)
 * @param scope Coroutine scope for the background task
 */
class QueueStatsPoller(
    private val postgRestClient: PostgRestClient,
    private val interval: Duration = 15.seconds,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) : AutoCloseable {

    private var job: Job? = null

    /**
     * Start the background polling task.
     */
    fun start() {
        if (job != null) {
            logger.warn { "QueueStatsPoller already running" }
            return
        }

        job = scope.launch {
            logger.info { "QueueStatsPoller started (interval=$interval)" }

            while (isActive) {
                try {
                    pollAndUpdate()
                } catch (e: Exception) {
                    logger.error(e) { "Error polling queue stats" }
                }

                delay(interval)
            }
        }
    }

    /**
     * Stop the background polling task.
     */
    fun stop() {
        job?.cancel()
        job = null
        logger.info { "QueueStatsPoller stopped" }
    }

    override fun close() {
        stop()
        scope.cancel()
    }

    private fun pollAndUpdate() {
        context(postgRestClient) {
            either { GetQueueStats() }
                .fold(
                    ifLeft = { error ->
                        logger.error { "Failed to get queue stats: $error" }
                    },
                    ifRight = { stats ->
                        stats.forEach { stat ->
                            JobMetrics.updateQueueDepth(stat.status.name, stat.count.toDouble())
                            JobMetrics.updateOldestAge(stat.status.name, stat.oldestAgeSeconds)
                        }
                        logger.debug { "Updated queue stats: ${stats.associate { it.status.name to it.count }}" }
                    }
                )
        }
    }
}
