package dev.dailywombat.cache.model

import dev.dailywombat.postgrest.PostgRestError

sealed interface CacheError {
    data class GeminiError(val message: String) : CacheError
    data class YouTubeError(val message: String) : CacheError
    data class DatabaseError(val underlying: PostgRestError) : CacheError
    data class InvalidVideoId(val videoId: String) : CacheError
    data class ApparentHallucination(
        val videoId: String,
        val expectedTitle: String,
        val actualTitle: String
    ) : CacheError
}
