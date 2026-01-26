package dev.dailywombat.jobs.runtime.listener.wakeup

import com.impossibl.postgres.api.jdbc.PGConnection
import dev.dailywombat.jobs.JobsSchema
import dev.dailywombat.jobs.runtime.listener.PGNotificationListenerSession
import dev.dailywombat.jobs.runtime.listener.ReconnectPolicy
import dev.dailywombat.jobs.runtime.listener.ReconnectPolicy.JitterExponentialBackoff
import io.github.oshai.kotlinlogging.KotlinLogging
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel

private val logger = KotlinLogging.logger {}

/**
 * Listens to PostgreSQL NOTIFY events on the job_notifications channel
 * and triggers job processing when new jobs are available.
 *
 * Uses a debouncing gate to coalesce multiple rapid notifications into
 * a single wake-up call, avoiding thundering herd issues.
 *
 * @param connectionSource Factory for creating PG connections (for LISTEN)
 * @param onWake Callback invoked when jobs may be ready for processing
 * @param scope Coroutine scope for background operations
 * @param policy Reconnection policy for handling connection failures
 */
class JobWakeupListener(
    connectionSource: () -> PGConnection,
    onWake: suspend () -> Unit,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val policy: ReconnectPolicy = JitterExponentialBackoff,
) : AutoCloseable {

    private sealed interface Msg {
        data object Start : Msg
        data object Stop : Msg
        data object Closed : Msg
    }

    private val control = Channel<Msg>(Channel.BUFFERED)
    private val gate = WakeUpGate(scope, onWake) {
        logger.error(it) { "Error in JobWakeupListener onWake" }
    }

    private var running = false
    private var generation = 0L
    private var reconnecting = false

    private val session = PGNotificationListenerSession(
        connectionSource = connectionSource,
        channel = JobsSchema.JOB_NOTIFICATIONS_CHANNEL,
        onClosed = { control.trySend(Msg.Closed) },
        onNotify = { gate.poke() }
    )

    private val actorJob = scope.launch {
        for (m: Msg in control) when (m) {
            Msg.Start -> if (!running) {
                running = true; generation++; connectLoop(generation)
            }

            Msg.Closed -> if (running) {
                generation++; connectLoop(generation)
            }

            Msg.Stop -> {
                running = false; generation++; reconnecting = false; session.close(); control.close()
            }
        }
    }

    fun start() {
        control.trySend(Msg.Start)
    }

    override fun close() {
        control.trySend(Msg.Stop)
        gate.close()
        actorJob.cancel()
    }

    private fun connectLoop(gen: Long) {
        if (reconnecting) return
        reconnecting = true

        scope.launch {
            session.close()
            var attempt = 0
            while (running && generation == gen) {
                attempt++
                try {
                    session.open()
                    logger.info { "Connected to job_notifications channel" }
                    reconnecting = false
                    return@launch
                } catch (t: Throwable) {
                    logger.warn(t) { "Failed to connect to job_notifications (attempt $attempt)" }
                    session.close()
                    delay(policy.delayMs(attempt))
                }
            }
            reconnecting = false
        }
    }
}
