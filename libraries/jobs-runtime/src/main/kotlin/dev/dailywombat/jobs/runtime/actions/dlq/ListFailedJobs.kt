@file:Suppress("PropertyName")

package dev.dailywombat.jobs.runtime.actions.dlq

import arrow.core.raise.Raise
import dev.dailywombat.jobs.JobsSchema
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.RpcPost
import org.http4k.format.Jackson
import java.time.Instant
import java.util.*

/**
 * List failed jobs with optional filters.
 *
 * Use this for DLQ inspection and monitoring.
 */
object ListFailedJobs {

    private data class FailedJobDto(
        val id: UUID,
        val job_type: String,
        val target_type: String,
        val target_id: UUID,
        val created_at: Instant,
        val completed_at: Instant?,
        val attempts: Int,
        val lease_count: Int,
        val last_error: String?,
        val replayed_from: UUID?
    ) {
        fun toModel(): FailedJob = FailedJob(
            id = id,
            jobType = job_type,
            targetType = target_type,
            targetId = target_id,
            createdAt = created_at,
            completedAt = completed_at,
            attempts = attempts,
            leaseCount = lease_count,
            lastError = last_error,
            replayedFrom = replayed_from
        )
    }

    private val listLens = Jackson.autoBody<List<FailedJobDto>>().toLens()

    /**
     * List failed jobs with optional filters.
     *
     * @param jobType Filter by job type (null = all)
     * @param targetType Filter by target type (null = all)
     * @param since Only jobs created after this time (null = no lower bound)
     * @param until Only jobs created before this time (null = no upper bound)
     * @param errorLike Filter by error message pattern - case insensitive (null = all)
     * @param limit Max results (default 50)
     * @param offset Skip first N results (default 0)
     */
    context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
    operator fun invoke(
        jobType: String? = null,
        targetType: String? = null,
        since: Instant? = null,
        until: Instant? = null,
        errorLike: String? = null,
        limit: Int = 50,
        offset: Int = 0
    ): List<FailedJob> {
        val rpcParams = mutableMapOf<String, Any>(
            "p_limit" to limit,
            "p_offset" to offset
        )

        jobType?.let { rpcParams["p_job_type"] = it }
        targetType?.let { rpcParams["p_target_type"] = it }
        since?.let { rpcParams["p_since"] = it }
        until?.let { rpcParams["p_until"] = it }
        errorLike?.let { rpcParams["p_error_like"] = it }

        val result = context(listLens) {
            pgRest(JobsSchema.ListFailedJobs, RpcPost(rpcParams) {
                contentProfile(JobsSchema)
            })
        }

        return result.map { it.toModel() }
    }
}
