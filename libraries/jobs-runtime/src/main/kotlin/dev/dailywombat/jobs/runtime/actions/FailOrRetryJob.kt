package dev.dailywombat.jobs.runtime.actions

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
 * Fail or retry a job.
 *
 * If the job has exhausted its retry attempts, marks it as 'failed'.
 * Otherwise, marks it as 'retrying' with capped exponential backoff and jitter.
 *
 * Backoff formula: min(base * 2^attempts, maxBackoff) * jitter
 * Jitter adds ±25% randomness to spread out retries and avoid thundering herd.
 */
object FailOrRetryJob {

    private val stringLens = Jackson.autoBody<String>().toLens()

    /**
     * Fail or retry a job.
     *
     * @param jobId The job to fail/retry
     * @param workerId Optional: only update if this worker holds the lease
     * @param maxAttempts Maximum attempts before permanent failure (default: 3)
     * @param backoffSeconds Base backoff duration in seconds (default: 30)
     * @param maxBackoffSeconds Maximum backoff cap in seconds (default: 900 = 15 min)
     * @param error Error message to record
     * @return The result of the operation
     */
    context(pgRest: PostgRestClient, raise: Raise<PostgRestError>)
    operator fun invoke(
        jobId: UUID,
        workerId: String? = null,
        maxAttempts: Int = 3,
        backoffSeconds: Int = 30,
        maxBackoffSeconds: Int = 900,
        error: String? = null
    ): FailOrRetryResult {
        val rpcParams = mutableMapOf<String, Any>(
            "p_job_id" to jobId.toString(),
            "p_max_attempts" to maxAttempts,
            "p_backoff_seconds" to backoffSeconds,
            "p_max_backoff_seconds" to maxBackoffSeconds
        )

        if (workerId != null) {
            rpcParams["p_worker_id"] = workerId
        }

        if (error != null) {
            rpcParams["p_error"] = error
        }

        return recover<PostgRestError, FailOrRetryResult>({
            val result: String = context(stringLens) {
                pgRest(JobsSchema.FailOrRetryJob, RpcPost(rpcParams) {
                    contentProfile(JobsSchema)
                    accept(Select.Accept.SingularRepresentation)
                })
            }

            when (result) {
                "retrying" -> FailOrRetryResult.RETRYING
                "failed" -> FailOrRetryResult.FAILED
                else -> FailOrRetryResult.NOT_FOUND
            }
        }) { err ->
            // Handle JB001 (job not found) as NOT_FOUND, re-raise other errors
            if (err is PostgRestError.SpecificError && err.body.code == JobsSchema.JobNotFound.name) {
                FailOrRetryResult.NOT_FOUND
            } else {
                raise.raise(err)
            }
        }
    }
}
