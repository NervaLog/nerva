package dev.template.app

import arrow.core.raise.context.either
import dev.nerva.PostgrestContainer
import dev.nerva.TestContainers
import dev.template.app.endpoints.api.GetSummary
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.Postgrest
import dev.dailywombat.postgrest.actions.Select
import io.kotest.matchers.collections.shouldHaveSize
import io.kotest.matchers.nulls.shouldNotBeNull
import io.kotest.matchers.shouldBe
import io.kotest.matchers.string.shouldNotBeBlank
import org.http4k.core.Body
import org.http4k.core.Method
import org.http4k.core.Request
import org.http4k.core.Status
import org.http4k.format.Jackson.auto
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.MethodOrderer
import org.junit.jupiter.api.Order
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestMethodOrder
import dev.dailywombat.cache.CacheSchema
import dev.dailywombat.cache.actions.GetCachedSummary
import dev.dailywombat.cache.config.GeminiConfig
import dev.dailywombat.cache.model.VideoSummary

@TestMethodOrder(MethodOrderer.OrderAnnotation::class)
class GetSummaryIntegrationTest {

    companion object {
        private const val VIDEO_ID = "_KLUQzcRhn8"

        private val geminiConfig: GeminiConfig by lazy {
            val apiKey = System.getenv("GEMINI_API_KEY")
                ?: error("GEMINI_API_KEY environment variable required for integration tests")
            GeminiConfig(apiKey = apiKey)
        }

        private lateinit var pgClient: PostgRestClient

        @BeforeAll
        @JvmStatic
        fun beforeAll() {
            TestContainers.start()
            pgClient = Postgrest.client(PostgrestContainer.config)
        }

        @AfterAll
        @JvmStatic
        fun afterAll() {
            TestContainers.stop()
        }
    }

    private val summaryResponseLens = Body.auto<VideoSummary>().toLens()
    private val errorResponseLens = Body.auto<GetSummary.ErrorResponse>().toLens()
    private val listLens = Body.auto<List<VideoSummary>>().toLens()

    @Test
    @Order(1)
    fun `1 - video is not cached initially`() {
        val result = either {
            context(pgClient, listLens) {
                pgClient(CacheSchema.VideoSummaries, Select<VideoSummary> {
                    acceptProfile(CacheSchema)
                    eq(VideoSummary::video_id, VIDEO_ID)
                })
            }
        }

        result.fold(
            ifLeft = { throw AssertionError("Database query failed: $it") },
            ifRight = { summaries ->
                summaries shouldHaveSize 0
            }
        )
    }

    @Test
    @Order(2)
    fun `2 - GET endpoint generates and returns summary for uncached video`() {
        val handler = context(pgClient, geminiConfig) {
            GetSummary()
        }

        val request = Request(Method.GET, "/api/v1/summary/$VIDEO_ID")
        val response = handler(request)

        response.status shouldBe Status.OK

        val summary = summaryResponseLens(response)
        summary.video_id shouldBe VIDEO_ID
        summary.summary.video_metadata.title.shouldNotBeBlank()
        summary.summary.video_metadata.channel.shouldNotBeBlank()
        summary.summary.key_topics.shouldNotBeNull()
        summary.created_at.shouldNotBeNull()
    }

    @Test
    @Order(3)
    fun `3 - video is now cached in database`() {
        val result = either {
            context(pgClient) {
                GetCachedSummary(VIDEO_ID)
            }
        }

        result.fold(
            ifLeft = { throw AssertionError("Cache lookup failed: $it") },
            ifRight = { cached ->
                cached.shouldNotBeNull()
                cached.video_id shouldBe VIDEO_ID
                cached.summary.video_metadata.title.shouldNotBeBlank()
            }
        )
    }

    @Test
    @Order(4)
    fun `4 - GET endpoint returns cached summary on second request`() {
        val handler = context(pgClient, geminiConfig) {
            GetSummary()
        }

        val request = Request(Method.GET, "/api/v1/summary/$VIDEO_ID")
        val response = handler(request)

        response.status shouldBe Status.OK

        val summary = summaryResponseLens(response)
        summary.video_id shouldBe VIDEO_ID
        summary.summary.video_metadata.title.shouldNotBeBlank()
    }

    @Test
    @Order(5)
    fun `5 - GET endpoint returns 400 for invalid video ID`() {
        val handler = context(pgClient, geminiConfig) {
            GetSummary()
        }

        val request = Request(Method.GET, "/api/v1/summary/invalid")
        val response = handler(request)

        response.status shouldBe Status.BAD_REQUEST

        val error = errorResponseLens(response)
        error.error shouldBe "invalid_video_id"
    }
}
