package dev.dailywombat.cache.actions

import arrow.core.raise.context.Raise
import arrow.core.raise.context.raise
import com.fasterxml.jackson.annotation.JsonInclude
import dev.template.resilience.ExternalService
import dev.template.resilience.resilientCallOrRaise
import okhttp3.OkHttpClient
import org.http4k.client.OkHttp
import java.time.Duration
import org.http4k.core.Body
import org.http4k.core.ContentType
import org.http4k.core.Method
import org.http4k.core.Request
import org.http4k.core.with
import org.http4k.format.Jackson
import org.http4k.format.Jackson.auto
import dev.dailywombat.cache.config.GeminiConfig
import dev.dailywombat.cache.config.SummarySource
import dev.dailywombat.cache.model.CacheError
import dev.dailywombat.cache.model.KeyTopic
import dev.dailywombat.cache.model.VideoMetadata
import dev.dailywombat.cache.model.VideoSummaryContent

object GenerateSummary {

    private val client = OkHttp(
        client = OkHttpClient.Builder()
            .readTimeout(Duration.ofMinutes(3))
            .build()
    )

    @JsonInclude(JsonInclude.Include.NON_NULL)
    private data class GeminiRequest(
        val contents: List<Content>,
        val generationConfig: GenerationConfig? = null
    )

    private data class Content(
        val parts: List<Part>
    )

    @JsonInclude(JsonInclude.Include.NON_NULL)
    private data class Part(
        val text: String? = null,
        val file_data: FileData? = null
    )

    private data class FileData(
        val file_uri: String,
        val mime_type: String
    )

    private data class GenerationConfig(
        val temperature: Double? = null,
        val responseMimeType: String? = null,
        val responseSchema: ResponseSchema? = null
    )

    private data class ResponseSchema(
        val type: String,
        val description: String? = null,
        val properties: Map<String, SchemaProperty>,
        val required: List<String>? = null
    )

    private data class SchemaProperty(
        val type: String,
        val description: String? = null,
        val properties: Map<String, SchemaProperty>? = null,
        val items: SchemaProperty? = null,
        val required: List<String>? = null
    )

    private val requestLens = Body.auto<GeminiRequest>().toLens()

    private val responseSchema = ResponseSchema(
        type = "OBJECT",
        description = "Summary of the YouTube video that was provided",
        properties = mapOf(
            "video_metadata" to SchemaProperty(
                type = "OBJECT",
                description = "Metadata about this specific video",
                properties = mapOf(
                    "title" to SchemaProperty(type = "STRING", description = "The exact title of this video as shown on YouTube"),
                    "channel" to SchemaProperty(type = "STRING", description = "The YouTube channel name that uploaded this video")
                ),
                required = listOf("title", "channel")
            ),
            "key_topics" to SchemaProperty(
                type = "ARRAY",
                description = "Key topics covered in this video with timestamps",
                items = SchemaProperty(
                    type = "OBJECT",
                    properties = mapOf(
                        "topic" to SchemaProperty(type = "STRING", description = "Brief topic name"),
                        "timestamp" to SchemaProperty(type = "STRING", description = "Timestamp in MM:SS format"),
                        "details" to SchemaProperty(type = "STRING", description = "What happens at this point in the video")
                    ),
                    required = listOf("topic", "timestamp", "details")
                )
            )
        ),
        required = listOf("video_metadata", "key_topics")
    )

    context(_: Raise<CacheError>)
    operator fun invoke(videoId: String, source: SummarySource, config: GeminiConfig): VideoSummaryContent {
        val videoUrl = "https://www.youtube.com/watch?v=$videoId"

        val geminiRequest = GeminiRequest(
            contents = listOf(
                Content(
                    parts = listOf(
                        Part(file_data = FileData(
                            file_uri = videoUrl,
                            mime_type = "video/youtube"
                        )),
                        Part(text = "Watch this YouTube video and extract its metadata and key topics.")
                    )
                )
            ),
            generationConfig = GenerationConfig(
                temperature = 0.0,
                responseMimeType = "application/json",
                responseSchema = responseSchema
            )
        )

        val url = "https://generativelanguage.googleapis.com/v1beta/models/${source.modelName}:generateContent?key=${config.apiKey}"

        val httpRequest = Request(Method.POST, url)
            .with(requestLens of geminiRequest)
            .header("Content-Type", ContentType.APPLICATION_JSON.toHeaderValue())

        val response = resilientCallOrRaise(
            service = ExternalService.GEMINI,
            onError = { CacheError.GeminiError("Failed to call Gemini API: ${it.message}") }
        ) {
            val resp = client(httpRequest)
            if (!resp.status.successful) {
                throw RuntimeException("Gemini API returned ${resp.status}: ${resp.bodyString()}")
            }
            resp
        }

        return parseResponse(response.bodyString())
    }

    context(_: Raise<CacheError>)
    private fun parseResponse(json: String): VideoSummaryContent {
        val node = try {
            Jackson.parse(json)
        } catch (e: Exception) {
            raise(CacheError.GeminiError("Failed to parse Gemini response: ${e.message}"))
        }

        val candidates = node["candidates"]
            ?: raise(CacheError.GeminiError("Missing candidates in response"))

        val content = candidates[0]?.get("content")?.get("parts")?.get(0)?.get("text")
            ?: raise(CacheError.GeminiError("Missing content in response"))

        val contentJson = try {
            Jackson.parse(content.asText())
        } catch (e: Exception) {
            raise(CacheError.GeminiError("Failed to parse content JSON: ${e.message}"))
        }

        val metadata = contentJson["video_metadata"]
        val topics = contentJson["key_topics"]

        return VideoSummaryContent(
            video_metadata = VideoMetadata(
                title = metadata?.get("title")?.asText() ?: "Unknown",
                channel = metadata?.get("channel")?.asText() ?: "Unknown"
            ),
            key_topics = topics?.map { topic ->
                KeyTopic(
                    topic = topic["topic"]?.asText() ?: "",
                    timestamp = topic["timestamp"]?.asText() ?: "",
                    details = topic["details"]?.asText() ?: ""
                )
            } ?: emptyList()
        )
    }
}
