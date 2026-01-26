package dev.dailywombat.jobs.runtime.listener.wakeup

import io.github.oshai.kotlinlogging.KotlinLogging
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

private val logger = KotlinLogging.logger {}

class WakeUpGate(
    scope: CoroutineScope,
    private val onWake: suspend () -> Unit,
    private val onWakeError: (suspend (Throwable) -> Unit)? = null
) : AutoCloseable {
    private val wakeups = Channel<Unit>(Channel.CONFLATED)
    private val job = scope.launch {
        for (u in wakeups) try {
            onWake()
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            logger.error(t) { "Error in WakeUpGate onWake" }
            onWakeError?.invoke(t)
        }
    }

    fun poke() {
        wakeups.trySend(Unit)
    }

    override fun close() {
        wakeups.close()
        job.cancel()
    }
}
