package dev.template.resilience

import arrow.resilience.CircuitBreaker
import arrow.resilience.Schedule
import arrow.resilience.retry
import io.github.oshai.kotlinlogging.KotlinLogging
import kotlinx.coroutines.runBlocking
import java.util.concurrent.ConcurrentHashMap
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

private val logger = KotlinLogging.logger {}

/**
 * Configuration for retry behavior.
 *
 * @property maxRetries Maximum number of retry attempts (not counting the initial attempt)
 * @property initialDelay Delay before the first retry
 * @property maxDelay Maximum delay between retries (caps exponential backoff)
 */
data class RetryConfig(
    val maxRetries: Int = 3,
    val initialDelay: Duration = 250.milliseconds,
    val maxDelay: Duration = 10.seconds
)

/**
 * Configuration for circuit breaker behavior.
 *
 * @property maxFailures Number of consecutive failures before opening the circuit
 * @property resetTimeout How long to wait before attempting recovery (half-open state)
 * @property exponentialBackoffFactor Multiplier for reset timeout on repeated failures
 * @property maxResetTimeout Maximum reset timeout (caps exponential growth)
 */
data class CircuitBreakerConfig(
    val maxFailures: Int = 5,
    val resetTimeout: Duration = 30.seconds,
    val exponentialBackoffFactor: Double = 2.0,
    val maxResetTimeout: Duration = 5.minutes
)

/**
 * Central resilience management for external API calls.
 *
 * Provides retry logic with exponential backoff and circuit breakers
 * for each external service. Circuit breakers are created lazily and
 * cached per service.
 *
 * ## Usage
 *
 * ```kotlin
 * val result = Resilience.withResilience(ExternalService.GEMINI) {
 *     callGeminiApi()
 * }
 * ```
 *
 * ## Circuit Breaker States
 *
 * - **Closed**: Normal operation, requests pass through
 * - **Open**: Too many failures, requests fail fast with [CircuitBreakerOpenException]
 * - **Half-Open**: Testing recovery, one request allowed through
 */
object Resilience {

    private val circuitBreakers = ConcurrentHashMap<ExternalService, CircuitBreaker>()

    /** Default retry configuration - suitable for most external APIs */
    val defaultRetryConfig = RetryConfig()

    /** Default circuit breaker configuration */
    val defaultCircuitBreakerConfig = CircuitBreakerConfig()

    /** Service-specific configurations (override defaults as needed) */
    private val serviceConfigs: Map<ExternalService, Pair<RetryConfig, CircuitBreakerConfig>> = mapOf(
        // Gemini can be slow, use longer timeouts
        ExternalService.GEMINI to Pair(
            RetryConfig(maxRetries = 2, initialDelay = 500.milliseconds, maxDelay = 15.seconds),
            CircuitBreakerConfig(maxFailures = 3, resetTimeout = 60.seconds)
        ),
        // YouTube oEmbed is fast and reliable
        ExternalService.YOUTUBE to Pair(
            RetryConfig(maxRetries = 3, initialDelay = 100.milliseconds),
            CircuitBreakerConfig(maxFailures = 5, resetTimeout = 30.seconds)
        ),
        // Stytch auth - balance reliability with user experience
        ExternalService.STYTCH to Pair(
            RetryConfig(maxRetries = 2, initialDelay = 200.milliseconds),
            CircuitBreakerConfig(maxFailures = 5, resetTimeout = 30.seconds)
        ),
        // Stripe - payment critical, be conservative
        ExternalService.STRIPE to Pair(
            RetryConfig(maxRetries = 2, initialDelay = 300.milliseconds),
            CircuitBreakerConfig(maxFailures = 3, resetTimeout = 60.seconds)
        )
    )

    /**
     * Get or create a circuit breaker for the given service.
     */
    fun circuitBreaker(service: ExternalService): CircuitBreaker {
        return circuitBreakers.computeIfAbsent(service) { svc ->
            val config = serviceConfigs[svc]?.second ?: defaultCircuitBreakerConfig
            runBlocking {
                CircuitBreaker(
                    openingStrategy = CircuitBreaker.OpeningStrategy.Count(config.maxFailures),
                    resetTimeout = config.resetTimeout,
                    exponentialBackoffFactor = config.exponentialBackoffFactor,
                    maxResetTimeout = config.maxResetTimeout
                )
            }
        }
    }

    /**
     * Execute an action with retry logic and circuit breaker protection.
     *
     * Uses exponential backoff with jitter, capped at maxRetries attempts.
     *
     * @param service The external service being called
     * @param action The action to execute
     * @return The result of the action
     * @throws CircuitBreaker.ExecutionRejected if the circuit is open
     * @throws Exception if all retries are exhausted
     */
    suspend fun <A> withResilience(
        service: ExternalService,
        action: suspend () -> A
    ): A {
        val cb = circuitBreaker(service)
        val config = serviceConfigs[service]?.first ?: defaultRetryConfig

        // Combine recurs (limit attempts) with exponential backoff (delays)
        val schedule = Schedule.recurs<Throwable>(config.maxRetries.toLong())
            .and(Schedule.exponential<Throwable>(config.initialDelay).jittered())

        return cb.protectOrThrow {
            schedule.retry {
                logger.debug { "[$service] Executing action" }
                action()
            }
        }
    }

    /**
     * Execute an action with retry logic and circuit breaker protection (blocking version).
     *
     * Use this when calling from non-suspend contexts.
     */
    fun <A> withResilienceBlocking(
        service: ExternalService,
        action: () -> A
    ): A = runBlocking {
        withResilience(service) { action() }
    }

    /**
     * Reset a circuit breaker to closed state. Useful for testing.
     */
    internal fun resetCircuitBreaker(service: ExternalService) {
        circuitBreakers.remove(service)
    }

    /**
     * Reset all circuit breakers. Useful for testing.
     */
    internal fun resetAllCircuitBreakers() {
        circuitBreakers.clear()
    }
}

/**
 * Exception thrown when a circuit breaker is open and rejecting requests.
 */
class CircuitBreakerOpenException(
    val service: ExternalService,
    message: String = "Circuit breaker for $service is open - failing fast"
) : RuntimeException(message)
