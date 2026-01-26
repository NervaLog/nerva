@file:Suppress("PropertyName")

package dev.dailywombat.jobs.runtime.actions

import arrow.core.raise.Raise
import dev.dailywombat.jobs.JobsSchema
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.RpcPost
import org.http4k.format.Jackson
import java.util.*

/**
 * Lease jobs for processing.
 *
 * Atomically selects up to N ready jobs, marks them as 'processing',
 * and assigns them to the worker. Uses FOR UPDATE SKIP LOCKED for
 * concurrent-safe leasing.
 */
object LeaseJobs {

    private data class LeasedJobDto(
        val id: UUID,
        val job_type: String,
        val target_type: String,
        val target_id: UUID,
        val params: Map<String, Any>?,
        val priority: Int,
        val attempts: Int,
        val lease_count: Int
    ) {
        fun toModel(): LeasedJob = LeasedJob(
            id = id,
            jobType = job_type,
            targetType = target_type,
            targetId = target_id,
            params = params,
            priority = priority,
            attempts = attempts,
            leaseCount = lease_count
        )
    }

    private val leasedJobsLens = Jackson.autoBody<List<LeasedJobDto>>().toLens()

    /**
     * Lease jobs for processing.
     *
     * @param workerId Unique ID for this worker
     * @param limit Maximum number of jobs to lease (default: 10)
     * @param leaseDurationMinutes How long the lease is valid (default: 2)
     * @param jobTypes Optional: only lease these job types (null = all)
     * @return List of leased jobs
     */
    context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
    operator fun invoke(
        workerId: String,
        limit: Int = 10,
        leaseDurationMinutes: Int = 2,
        jobTypes: List<String>? = null
    ): List<LeasedJob> {
        val rpcParams = mutableMapOf<String, Any>(
            "p_worker_id" to workerId,
            "p_limit" to limit,
            "p_lease_duration_minutes" to leaseDurationMinutes
        )

        if (jobTypes != null) {
            rpcParams["p_job_types"] = jobTypes
        }

        val result = context(leasedJobsLens) {
            pgRest(JobsSchema.LeaseJobs, RpcPost(rpcParams) {
                contentProfile(JobsSchema)
            })
        }

        return result.map { it.toModel() }
    }
}
