package dev.dailywombat.cache.actions

import arrow.core.raise.context.Raise
import dev.template.resilience.ExternalService
import dev.template.resilience.resilientCallOrRaise
import org.http4k.client.JavaHttpClient
import org.http4k.core.Method
import org.http4k.core.Request
import org.http4k.format.Jackson
import dev.dailywombat.cache.model.CacheError

data class YouTubeMetadata(
    val title: String,
    val channel: String
)

object FetchYouTubeMetadata {

    private val client = JavaHttpClient()

    context(_: Raise<CacheError>)
    operator fun invoke(videoId: String): YouTubeMetadata {
        val url = "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=$videoId&format=json"

        val json = resilientCallOrRaise(
            service = ExternalService.YOUTUBE,
            onError = { CacheError.YouTubeError("Failed to fetch YouTube metadata: ${it.message}") }
        ) {
            val response = client(Request(Method.GET, url))
            if (!response.status.successful) {
                throw RuntimeException("YouTube oEmbed returned ${response.status}")
            }
            Jackson.parse(response.bodyString())
        }

        return YouTubeMetadata(
            title = json["title"]?.asText() ?: "Unknown",
            channel = json["author_name"]?.asText() ?: "Unknown"
        )
    }
}
