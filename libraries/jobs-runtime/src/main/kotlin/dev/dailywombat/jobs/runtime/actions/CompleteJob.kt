package dev.dailywombat.jobs.runtime.actions

import arrow.core.raise.Raise
import dev.dailywombat.jobs.JobsSchema
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.RpcPost
import dev.dailywombat.postgrest.actions.Select
import org.http4k.format.Jackson
import java.util.*

/**
 * Mark a job as completed.
 */
object CompleteJob {

    private val booleanLens = Jackson.autoBody<Boolean>().toLens()

    /**
     * Mark a job as completed.
     *
     * @param jobId The job to complete
     * @param workerId Optional: only complete if this worker holds the lease
     * @return true if the job was completed, false otherwise
     */
    context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
    operator fun invoke(jobId: UUID, workerId: String? = null): Boolean {
        val rpcParams = mutableMapOf<String, Any>("p_job_id" to jobId.toString())

        if (workerId != null) {
            rpcParams["p_worker_id"] = workerId
        }

        return context(booleanLens) {
            pgRest(JobsSchema.CompleteJob, RpcPost(rpcParams) {
                contentProfile(JobsSchema)
                accept(Select.Accept.SingularRepresentation)
            })
        }
    }
}
