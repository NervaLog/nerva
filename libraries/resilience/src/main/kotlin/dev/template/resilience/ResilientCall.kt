package dev.template.resilience

import arrow.core.Either
import arrow.core.left
import arrow.core.raise.context.Raise
import arrow.core.raise.context.raise
import arrow.core.right
import arrow.resilience.CircuitBreaker
import io.github.oshai.kotlinlogging.KotlinLogging

private val logger = KotlinLogging.logger {}

/**
 * Result of a resilient call that captures both the success value
 * and information about retries/circuit breaker state.
 */
sealed interface ResilientResult<out A> {
    data class Success<A>(val value: A, val retriesUsed: Int = 0) : ResilientResult<A>
    data class CircuitOpen(val service: ExternalService) : ResilientResult<Nothing>
    data class Failure(val exception: Throwable, val retriesExhausted: Int) : ResilientResult<Nothing>
}

/**
 * Execute an external API call with resilience protection.
 *
 * This is the primary entry point for making resilient external calls.
 * It combines retry logic with circuit breaker protection.
 *
 * ## Example
 *
 * ```kotlin
 * context(Raise<CacheError>)
 * fun callGemini(): Response {
 *     return resilientCall(ExternalService.GEMINI) {
 *         client(httpRequest)
 *     }.mapError { CacheError.GeminiError(it.message ?: "Unknown error") }
 * }
 * ```
 *
 * @param service The external service being called
 * @param action The HTTP/API call to execute
 * @return Either the result or the last exception encountered
 */
fun <A> resilientCall(
    service: ExternalService,
    action: () -> A
): Either<Throwable, A> {
    return try {
        Resilience.withResilienceBlocking(service, action).right()
    } catch (e: CircuitBreaker.ExecutionRejected) {
        logger.warn { "[$service] Circuit breaker open, failing fast" }
        CircuitBreakerOpenException(service).left()
    } catch (e: Exception) {
        logger.error(e) { "[$service] Call failed after retries" }
        e.left()
    }
}

/**
 * Execute a resilient call and raise on failure.
 *
 * Convenience function for use within Raise contexts that automatically
 * converts failures to raised errors.
 *
 * ## Example
 *
 * ```kotlin
 * context(Raise<CacheError>)
 * fun callGemini(): Response {
 *     return resilientCallOrRaise(
 *         service = ExternalService.GEMINI,
 *         onError = { e -> CacheError.GeminiError(e.message ?: "Unknown error") }
 *     ) {
 *         client(httpRequest)
 *     }
 * }
 * ```
 *
 * @param service The external service being called
 * @param onError Transform the exception into the appropriate error type
 * @param action The HTTP/API call to execute
 * @return The successful result
 * @raises E if the call fails
 */
context(r: Raise<E>)
fun <E, A> resilientCallOrRaise(
    service: ExternalService,
    onError: (Throwable) -> E,
    action: () -> A
): A {
    return resilientCall(service, action).fold(
        ifLeft = { e -> raise(onError(e)) },
        ifRight = { it }
    )
}

/**
 * Extension to map the error type from a resilient call result.
 *
 * ## Example
 *
 * ```kotlin
 * resilientCall(ExternalService.GEMINI) { api.call() }
 *     .mapError { CacheError.GeminiError(it.message) }
 *     .bind()
 * ```
 */
fun <E, A> Either<Throwable, A>.mapError(transform: (Throwable) -> E): Either<E, A> =
    mapLeft(transform)
