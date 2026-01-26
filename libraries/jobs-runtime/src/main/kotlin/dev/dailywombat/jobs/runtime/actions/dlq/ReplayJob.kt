package dev.dailywombat.jobs.runtime.actions.dlq

import arrow.core.raise.Raise
import arrow.core.raise.recover
import dev.dailywombat.jobs.JobsSchema
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.RpcPost
import dev.dailywombat.postgrest.actions.Select
import org.http4k.format.Jackson
import java.util.*

/**
 * Replay a failed job by creating a new job with the same parameters.
 *
 * The original job stays in 'failed' status for audit trail.
 * The new job references the original via replayed_from.
 */
object ReplayJob {

    private val uuidLens = Jackson.autoBody<UUID>().toLens()

    /**
     * Replay a failed job.
     *
     * @param jobId The failed job to replay
     * @return ReplayResult indicating success or failure reason
     */
    context(pgRest: PostgRestClient, raise: Raise<PostgRestError>)
    operator fun invoke(jobId: UUID): ReplayResult {
        return recover<PostgRestError, ReplayResult>({
            val newId = context(uuidLens) {
                pgRest(JobsSchema.ReplayJob, RpcPost(mapOf("p_job_id" to jobId)) {
                    contentProfile(JobsSchema)
                    accept(Select.Accept.SingularRepresentation)
                })
            }
            ReplayResult.Success(newId)
        }) { err ->
            when {
                err is PostgRestError.SpecificError && err.body.code == JobsSchema.JobNotFoundForReplay.name ->
                    ReplayResult.NotFound

                err is PostgRestError.SpecificError && err.body.code == JobsSchema.JobNotFailed.name ->
                    ReplayResult.NotFailed

                else -> raise.raise(err)
            }
        }
    }
}
