package dev.dailywombat.jobs.runtime.actions

import arrow.core.raise.Raise
import dev.dailywombat.jobs.Job
import dev.dailywombat.jobs.UnitJob
import dev.dailywombat.jobs.actions.EnqueueJob
import dev.dailywombat.jobs.actions.EnqueueJobInput
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import org.http4k.format.Jackson
import java.time.Instant
import java.util.*

/**
 * Type-safe job enqueueing extensions.
 *
 * Instead of passing stringly-typed job names:
 * ```
 * EnqueueJob(EnqueueJobInput(
 *     jobType = "run_planer",  // typo - fails at runtime!
 *     ...
 * ))
 * ```
 *
 * Use the Job object directly:
 * ```
 * RunPlannerJob.enqueue(
 *     targetType = "surface",
 *     targetId = surfaceId,
 *     params = RunPlannerJob.Params(cursor = 42)  // type-safe!
 * )
 * ```
 *
 * Benefits:
 * - Compile-time safety: can't enqueue non-existent job types
 * - Type-safe params: must match the Job's declared param type
 * - IDE autocomplete for job types and params
 */

private val mapper = Jackson.mapper

/**
 * Enqueue this job with type-safe parameters.
 *
 * @param targetType The type of entity this job operates on (e.g., "surface", "plan")
 * @param targetId The UUID of the target entity
 * @param params The job parameters (must match this Job's param type)
 * @param idempotencyKey Optional key for deduplication
 * @param priority Higher = more urgent (default 0)
 * @param availableAt When the job becomes available (default: now)
 * @return The job ID (existing ID if idempotency key matched)
 */
context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
fun <A : Any> Job<A>.enqueue(
    targetType: String,
    targetId: UUID,
    params: A,
    idempotencyKey: String? = null,
    priority: Int = 0,
    availableAt: Instant? = null
): UUID {
    @Suppress("UNCHECKED_CAST")
    val paramsMap = mapper.convertValue(params, Map::class.java) as Map<String, Any>?

    return EnqueueJob(
        EnqueueJobInput(
            jobType = type,
            targetType = targetType,
            targetId = targetId,
            idempotencyKey = idempotencyKey,
            params = paramsMap,
            priority = priority,
            availableAt = availableAt
        )
    )
}

/**
 * Enqueue a parameterless job.
 *
 * @param targetType The type of entity this job operates on
 * @param targetId The UUID of the target entity
 * @param idempotencyKey Optional key for deduplication
 * @param priority Higher = more urgent (default 0)
 * @param availableAt When the job becomes available (default: now)
 * @return The job ID (existing ID if idempotency key matched)
 */
context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
fun UnitJob.enqueue(
    targetType: String,
    targetId: UUID,
    idempotencyKey: String? = null,
    priority: Int = 0,
    availableAt: Instant? = null
): UUID = EnqueueJob(
    EnqueueJobInput(
        jobType = type,
        targetType = targetType,
        targetId = targetId,
        idempotencyKey = idempotencyKey,
        params = null,
        priority = priority,
        availableAt = availableAt
    )
)
