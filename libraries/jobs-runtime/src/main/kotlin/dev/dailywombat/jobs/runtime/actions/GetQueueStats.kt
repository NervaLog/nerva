package dev.dailywombat.jobs.runtime.actions

import arrow.core.raise.Raise
import dev.dailywombat.jobs.JobStatus
import dev.dailywombat.jobs.JobsSchema
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.RpcPost
import org.http4k.format.Jackson

/**
 * Get queue statistics for metrics gauges.
 *
 * Returns count and oldest job age by status (pending, processing, retrying, failed).
 */
object GetQueueStats {

    private data class QueueStatDto(
        val status: String,
        val count: Long,
        val oldest_age_seconds: Double
    )

    private val listLens = Jackson.autoBody<List<QueueStatDto>>().toLens()

    /**
     * Get queue statistics.
     *
     * @return List of stats, one per status
     */
    context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
    operator fun invoke(): List<QueueStat> {
        val result = context(listLens) {
            pgRest(JobsSchema.QueueStats, RpcPost(emptyMap<String, Any>()) {
                contentProfile(JobsSchema)
            })
        }

        return result.map { dto ->
            QueueStat(
                status = JobStatus.fromString(dto.status),
                count = dto.count,
                oldestAgeSeconds = dto.oldest_age_seconds
            )
        }
    }
}
