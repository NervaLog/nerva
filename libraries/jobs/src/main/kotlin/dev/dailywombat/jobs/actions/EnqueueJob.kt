package dev.dailywombat.jobs.actions

import arrow.core.raise.Raise
import dev.dailywombat.jobs.JobsSchema
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.RpcPost
import dev.dailywombat.postgrest.actions.Select
import org.http4k.format.Jackson
import java.time.Instant
import java.util.*

/**
 * Input for enqueuing a job.
 */
data class EnqueueJobInput(
    val jobType: String,
    val targetType: String,
    val targetId: UUID,
    val idempotencyKey: String? = null,
    val params: Map<String, Any>? = null,
    val priority: Int = 0,
    val availableAt: Instant? = null
)

/**
 * Enqueue a job for async processing.
 *
 * If an idempotency key is provided and a job with that key already exists,
 * the existing job ID is returned (deduplication).
 */
object EnqueueJob {

    private val uuidLens = Jackson.autoBody<UUID>().toLens()

    context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
    operator fun invoke(input: EnqueueJobInput): UUID {
        val rpcParams = mutableMapOf<String, Any>(
            "p_job_type" to input.jobType,
            "p_target_type" to input.targetType,
            "p_target_id" to input.targetId.toString(),
            "p_priority" to input.priority,
            "p_available_at" to (input.availableAt ?: Instant.now()).toString()
        )

        if (input.idempotencyKey != null) {
            rpcParams["p_idempotency_key"] = input.idempotencyKey
        }

        if (input.params != null) {
            rpcParams["p_params"] = input.params
        }

        return context(uuidLens) {
            pgRest(JobsSchema.EnqueueJob, RpcPost(rpcParams) {
                contentProfile(JobsSchema)
                accept(Select.Accept.SingularRepresentation)
            })
        }
    }
}
