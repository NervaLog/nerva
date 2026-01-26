package dev.dailywombat.cache.config

import com.fasterxml.jackson.annotation.JsonValue
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes

enum class SummarySource(
    @JsonValue val modelName: String,
    val tokensPerMinute: Int,
    val maxDuration: Duration
) {
    GEMINI_2_5_FLASH_LITE("gemini-2.5-flash-lite", tokensPerMinute = 17_800, maxDuration = 55.minutes),
    GEMINI_2_5_FLASH("gemini-2.5-flash", tokensPerMinute = 17_800, maxDuration = 55.minutes),
    GEMINI_2_5_PRO("gemini-2.5-pro", tokensPerMinute = 17_800, maxDuration = 55.minutes),
    GEMINI_3_FLASH_PREVIEW("gemini-3-flash-preview", tokensPerMinute = 5_500, maxDuration = 180.minutes),
    GEMINI_3_PRO_PREVIEW("gemini-3-pro-preview", tokensPerMinute = 5_500, maxDuration = 180.minutes);

    companion object {
        val DEFAULT = GEMINI_2_5_FLASH_LITE

        fun selectForDuration(duration: Duration): SummarySource = when {
            duration <= GEMINI_2_5_FLASH_LITE.maxDuration -> GEMINI_2_5_FLASH_LITE
            duration <= GEMINI_3_FLASH_PREVIEW.maxDuration -> GEMINI_3_FLASH_PREVIEW
            else -> GEMINI_3_FLASH_PREVIEW
        }
    }
}
