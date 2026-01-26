package dev.template.app.endpoints.api

import arrow.core.raise.context.either
import dev.dailywombat.postgrest.PostgRestClient
import org.http4k.core.Method
import org.http4k.core.Response
import org.http4k.core.Status
import org.http4k.format.Jackson
import org.http4k.lens.Path
import org.http4k.lens.string
import org.http4k.routing.RoutingHttpHandler
import org.http4k.routing.bind
import dev.dailywombat.cache.actions.GetOrSummarize
import dev.dailywombat.cache.config.GeminiConfig
import dev.dailywombat.cache.model.CacheError
import dev.dailywombat.cache.model.VideoSummary

object GetSummary {

    private val videoIdLens = Path.string().of("videoId")
    private val responseLens = Jackson.autoBody<VideoSummary>().toLens()
    private val errorLens = Jackson.autoBody<ErrorResponse>().toLens()

    data class ErrorResponse(
        val error: String,
        val message: String
    )

    context(client: PostgRestClient, geminiConfig: GeminiConfig)
    operator fun invoke(): RoutingHttpHandler =
        "/api/v1/summary/{videoId}" bind Method.GET to { request ->
            val videoId = videoIdLens(request)

            either { GetOrSummarize(videoId, geminiConfig) }.fold(
                ifLeft = { error -> errorResponse(error) },
                ifRight = { summary -> responseLens(summary, Response(Status.OK)) }
            )
        }

    private fun errorResponse(error: CacheError): Response =
        when (error) {
            is CacheError.InvalidVideoId -> errorLens(
                ErrorResponse("invalid_video_id", "Invalid YouTube video ID: ${error.videoId}"),
                Response(Status.BAD_REQUEST)
            )
            is CacheError.GeminiError -> errorLens(
                ErrorResponse("generation_failed", error.message),
                Response(Status.BAD_GATEWAY)
            )
            is CacheError.YouTubeError -> errorLens(
                ErrorResponse("youtube_fetch_failed", error.message),
                Response(Status.BAD_GATEWAY)
            )
            is CacheError.DatabaseError -> errorLens(
                ErrorResponse("database_error", "Database operation failed"),
                Response(Status.INTERNAL_SERVER_ERROR)
            )
            is CacheError.ApparentHallucination -> errorLens(
                ErrorResponse("hallucination_detected",
                    "Summary appears to be for wrong video. Expected: '${error.expectedTitle}', got: '${error.actualTitle}'"),
                Response(Status.BAD_GATEWAY)
            )
        }
}
