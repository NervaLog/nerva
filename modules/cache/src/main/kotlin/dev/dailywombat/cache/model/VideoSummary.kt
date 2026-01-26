package dev.dailywombat.cache.model

import org.http4k.core.Uri
import dev.dailywombat.cache.config.SummarySource
import java.time.Instant

data class VideoSummary(
    val video_id: String,
    val url: Uri,
    val source: SummarySource?,
    val summary: VideoSummaryContent,
    val created_at: Instant
)
