package dev.dailywombat.cache

import dev.dailywombat.flyway.modules.Entity
import dev.dailywombat.flyway.modules.ModuleSchema

object CacheSchema : ModuleSchema() {
    override val name = "cache"

    val VideoSummaries = Entity.table("video_summaries", "Cached YouTube video summaries")
}
