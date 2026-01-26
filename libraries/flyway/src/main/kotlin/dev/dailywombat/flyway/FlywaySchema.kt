@file:Suppress("HasPlatformType")

package dev.dailywombat.flyway

import dev.dailywombat.flyway.modules.ModuleSchema

object FlywaySchema : ModuleSchema() {
    override val name = FlywayConfig.DefaultSchema
}