package dev.dailywombat.cache.model

data class VideoSummaryContent(
    val video_metadata: VideoMetadata,
    val key_topics: List<KeyTopic>
)

data class VideoMetadata(
    val title: String,
    val channel: String
)

data class KeyTopic(
    val topic: String,
    val timestamp: String,
    val details: String
)
