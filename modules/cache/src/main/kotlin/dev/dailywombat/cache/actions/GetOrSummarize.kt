package dev.dailywombat.cache.actions

import arrow.core.raise.context.Raise
import arrow.core.raise.context.either
import arrow.core.raise.context.raise
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.cache.config.GeminiConfig
import dev.dailywombat.cache.config.SummarySource
import dev.dailywombat.cache.model.CacheError
import dev.dailywombat.cache.model.VideoSummary
import org.http4k.core.Uri
import dev.dailywombat.cache.model.VideoSummaryContent

object GetOrSummarize {

    private val VIDEO_ID_REGEX = Regex("^[a-zA-Z0-9_-]{11}$")
    private fun youtubeUrl(videoId: String) = Uri.of("https://www.youtube.com/watch?v=$videoId")

    context(client: PostgRestClient, _: Raise<CacheError>)
    operator fun invoke(videoId: String, geminiConfig: GeminiConfig): VideoSummary {
        if (!VIDEO_ID_REGEX.matches(videoId)) {
            raise(CacheError.InvalidVideoId(videoId))
        }

        val cached = getCached(videoId)
        if (cached != null) {
            return cached
        }

        // Fetch YouTube metadata for validation
        val ytMeta = FetchYouTubeMetadata(videoId)

        val url = youtubeUrl(videoId)
        val source = SummarySource.DEFAULT
        val content = GenerateSummary(videoId, source, geminiConfig)

        // Validate summary matches the actual video
        if (!titlesMatch(ytMeta.title, content.video_metadata.title)) {
            raise(CacheError.ApparentHallucination(
                videoId = videoId,
                expectedTitle = ytMeta.title,
                actualTitle = content.video_metadata.title
            ))
        }

        return cacheSummary(videoId, url, source, content)
    }

    private fun titlesMatch(expected: String, actual: String): Boolean {
        val e = expected.lowercase()
        val a = actual.lowercase()
        // Exact match or one contains the other
        if (e == a || e.contains(a) || a.contains(e)) return true
        // Check word overlap (at least 50% of words match)
        val expectedWords = e.split(Regex("[^a-z0-9]+")).filter { it.length > 2 }.toSet()
        val actualWords = a.split(Regex("[^a-z0-9]+")).filter { it.length > 2 }.toSet()
        if (expectedWords.isEmpty()) return true
        val overlap = expectedWords.intersect(actualWords).size
        return overlap >= expectedWords.size / 2
    }

    context(client: PostgRestClient, _: Raise<CacheError>)
    private fun getCached(videoId: String): VideoSummary? =
        either { GetCachedSummary(videoId) }.fold(
            ifLeft = { raise(CacheError.DatabaseError(it)) },
            ifRight = { it }
        )

    context(client: PostgRestClient, _: Raise<CacheError>)
    private fun cacheSummary(videoId: String, url: Uri, source: SummarySource, content: VideoSummaryContent): VideoSummary =
        either { CacheSummary(videoId, url, source, content) }.fold(
            ifLeft = { raise(CacheError.DatabaseError(it)) },
            ifRight = { it }
        )
}
