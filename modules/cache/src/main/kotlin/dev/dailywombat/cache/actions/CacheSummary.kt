package dev.dailywombat.cache.actions

import arrow.core.raise.context.Raise
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.Insert
import dev.dailywombat.postgrest.actions.Select
import org.http4k.format.Jackson
import dev.dailywombat.cache.CacheSchema
import dev.dailywombat.cache.config.SummarySource
import dev.dailywombat.cache.model.VideoSummary
import org.http4k.core.Uri
import dev.dailywombat.cache.model.VideoSummaryContent

object CacheSummary {

    private data class InsertPayload(
        val video_id: String,
        val url: Uri,
        val source: SummarySource,
        val summary: VideoSummaryContent
    )

    private val resultLens = Jackson.autoBody<VideoSummary>().toLens()

    context(client: PostgRestClient, _: Raise<PostgRestError>)
    operator fun invoke(videoId: String, url: Uri, source: SummarySource, content: VideoSummaryContent): VideoSummary =
        context(resultLens) {
            client(
                CacheSchema.VideoSummaries,
                Insert(InsertPayload(videoId, url, source, content)) {
                    contentProfile(CacheSchema)
                    accept(Select.Accept.SingularRepresentation)
                }
            )
        }
}
