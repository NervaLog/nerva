package dev.dailywombat.cache

import arrow.core.raise.context.Raise
import arrow.core.raise.context.either
import com.fasterxml.jackson.databind.JsonNode
import dev.dailywombat.PostgrestContainer
import dev.dailywombat.TestContainers
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.Postgrest
import dev.dailywombat.postgrest.actions.Select
import io.kotest.matchers.shouldBe
import org.http4k.format.Jackson.auto
import org.http4k.core.Body
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test

class CacheTests {

    companion object {
        @BeforeAll
        @JvmStatic
        fun before() = TestContainers.start()

        @AfterAll
        @JvmStatic
        fun after() = TestContainers.stop()
    }

    @Test
    fun `video_summaries table is queryable via PostgREST`() {
        val result = either {
            context(Postgrest.client(PostgrestContainer.config)) {
                queryVideoSummaries()
            }
        }
        result.fold(
            ifLeft = { error -> throw AssertionError("PostgREST query failed: $error") },
            ifRight = { summaries -> summaries.size shouldBe 0 }
        )
    }
}

private val videoSummariesLens = Body.auto<List<JsonNode>>().toLens()

context(client: PostgRestClient, _: Raise<PostgRestError>)
private fun queryVideoSummaries(): List<JsonNode> = context(videoSummariesLens) {
    client(CacheSchema.VideoSummaries, Select {
        acceptProfile(CacheSchema)
    })
}
