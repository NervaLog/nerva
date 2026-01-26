package dev.dailywombat.jobs.runtime.listener

import kotlin.math.min
import kotlin.random.Random

sealed interface ReconnectPolicy {
    fun delayMs(attempt: Int): Long

    object JitterExponentialBackoff : ReconnectPolicy {
        override fun delayMs(attempt: Int): Long {
            val base = 250L
            val cap = 30_000L
            val exp = base * (1L shl min(attempt, 10))
            val jitter = Random.nextLong(0, 250L)
            return min(exp + jitter, cap)
        }
    }
}
