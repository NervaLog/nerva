package dev.dailywombat.jobs.runtime.actions

import arrow.core.raise.Raise
import dev.dailywombat.jobs.JobsSchema
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.RpcPost
import dev.dailywombat.postgrest.actions.Select
import org.http4k.format.Jackson

/**
 * Release jobs with expired leases back to the queue.
 *
 * When a worker crashes or times out mid-processing, jobs become "stale" -
 * stuck in 'processing' with an expired lease. This action releases them
 * so other workers can pick them up.
 *
 * Should be called periodically (e.g., every 30-60 seconds) by a background task.
 */
object ReleaseStaleJobs {

    private val intLens = Jackson.autoBody<Int>().toLens()

    /**
     * Release stale jobs.
     *
     * @param limit Maximum number of stale jobs to release (default: 100)
     * @return Number of jobs released
     */
    context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
    operator fun invoke(limit: Int = 100): Int {
        val rpcParams = mapOf("p_limit" to limit)

        return context(intLens) {
            pgRest(JobsSchema.ReleaseStaleJobs, RpcPost(rpcParams) {
                contentProfile(JobsSchema)
                accept(Select.Accept.SingularRepresentation)
            })
        }
    }
}
