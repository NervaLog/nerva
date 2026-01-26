package dev.dailywombat.cache.actions

import arrow.core.raise.context.Raise
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.Select
import org.http4k.format.Jackson
import dev.dailywombat.cache.CacheSchema
import dev.dailywombat.cache.model.VideoSummary

object GetCachedSummary {

    private val lens = Jackson.autoBody<List<VideoSummary>>().toLens()

    context(client: PostgRestClient, _: Raise<PostgRestError>)
    operator fun invoke(videoId: String): VideoSummary? = context(lens) {
        client(CacheSchema.VideoSummaries, Select<VideoSummary> {
            acceptProfile(CacheSchema)
            eq(VideoSummary::video_id, videoId)
        }).firstOrNull()
    }
}
