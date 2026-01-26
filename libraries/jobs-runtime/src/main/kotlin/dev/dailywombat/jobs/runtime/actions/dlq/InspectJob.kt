@file:Suppress("PropertyName")

package dev.dailywombat.jobs.runtime.actions.dlq

import arrow.core.raise.Raise
import dev.dailywombat.jobs.JobStatus
import dev.dailywombat.jobs.JobsSchema
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.RpcPostSingle
import java.time.Instant
import java.util.*

/**
 * Get full details of a job (any status).
 *
 * Use this to inspect a job's params, full error message, and history.
 */
object InspectJob {

    private data class JobDetailsDto(
        val id: UUID,
        val job_type: String,
        val idempotency_key: String?,
        val target_type: String,
        val target_id: UUID,
        val params: Map<String, Any>?,
        val priority: Int,
        val created_at: Instant,
        val available_at: Instant,
        val status: String,
        val lease_owner: String?,
        val lease_until: Instant?,
        val lease_count: Int,
        val attempts: Int,
        val last_error: String?,
        val completed_at: Instant?,
        val replayed_from: UUID?
    ) {
        fun toModel(): JobDetails = JobDetails(
            id = id,
            jobType = job_type,
            idempotencyKey = idempotency_key,
            targetType = target_type,
            targetId = target_id,
            params = params,
            priority = priority,
            createdAt = created_at,
            availableAt = available_at,
            status = JobStatus.fromString(status),
            leaseOwner = lease_owner,
            leaseUntil = lease_until,
            leaseCount = lease_count,
            attempts = attempts,
            lastError = last_error,
            completedAt = completed_at,
            replayedFrom = replayed_from
        )
    }

    private data class Args(val p_job_id: UUID)

    /**
     * Get full details of a job.
     *
     * @param jobId The job ID to inspect
     * @return Full job details, or null if not found
     */
    context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
    operator fun invoke(jobId: UUID): JobDetails? {
        val result: JobDetailsDto? = RpcPostSingle<Args, JobDetailsDto>(
            entity = JobsSchema.InspectJob,
            args = Args(jobId),
            contentProfile = JobsSchema
        )
        return result?.toModel()
    }
}
