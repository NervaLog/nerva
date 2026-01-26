package dev.dailywombat.jobs

import arrow.core.Either
import arrow.core.left
import arrow.core.right
import com.fasterxml.jackson.databind.ObjectMapper
import org.http4k.format.Jackson
import kotlin.reflect.KClass

/**
 * Base class for job handlers.
 *
 * Jobs are discovered via classpath scanning and registered automatically.
 * Each job type should be a Kotlin object extending this class.
 *
 * Usage:
 * ```
 * object RunPlannerJob : Job<RunPlannerJob.Params>("run_planner", Params::class) {
 *     data class Params(val surfaceId: UUID)
 *
 *     override suspend operator fun invoke(params: Params): JobResult {
 *         // ... do work ...
 *         return JobResult.Success
 *     }
 * }
 *
 * // Can be called directly:
 * RunPlannerJob(Params(surfaceId))
 * ```
 *
 * For custom deserialization (e.g., Stripe events), override [deserialize]:
 * ```
 * object ProcessStripeEvent : Job<Event>("stripe_event", Event::class) {
 *     override fun deserialize(json: Map<String, Any>?, mapper: ObjectMapper): Either<String, Event> {
 *         val payload = json?.get("payload") as? String ?: return "Missing payload".left()
 *         return Either.catch { Webhook.constructEvent(payload, sig, secret) }
 *             .mapLeft { "Invalid event: ${it.message}" }
 *     }
 * }
 * ```
 *
 * @param A The typed params for this job (deserialized from JSONB)
 * @param type The job type string (must match what's stored in the database)
 * @param paramsClass KClass for deserializing params from JSON
 */
abstract class Job<A : Any>(
    val type: String,
    private val paramsClass: KClass<A>
) {
    /**
     * Execute the job with typed params.
     */
    abstract suspend operator fun invoke(params: A): JobResult

    /**
     * Deserialize params from the database representation.
     *
     * Override this for custom deserialization (e.g., Stripe SDK, protobuf).
     * The default implementation uses Jackson's convertValue.
     *
     * @param json The params as stored in the database (JSONB → Map)
     * @param mapper Jackson mapper for default deserialization
     * @return Either an error message (Left) or the typed params (Right)
     */
    open fun deserialize(
        json: Map<String, Any>?,
        mapper: ObjectMapper = Jackson.mapper
    ): Either<String, A> = try {
        mapper.convertValue(json, paramsClass.java).right()
    } catch (e: Exception) {
        "Deserialization failed: ${e.message}".left()
    }

    /**
     * Parse JSON params and return a suspended invocation.
     * Used by the job processor to execute jobs.
     *
     * If deserialization fails, returns a function that yields [JobResult.Fail].
     * This prevents wasting retries on jobs with malformed params.
     */
    open fun parseAndInvoke(
        json: Map<String, Any>?,
        mapper: ObjectMapper = Jackson.mapper
    ): suspend () -> JobResult = deserialize(json, mapper).fold(
        ifLeft = { error -> { JobResult.Fail(error) } },
        ifRight = { params -> { invoke(params) } }
    )
}

