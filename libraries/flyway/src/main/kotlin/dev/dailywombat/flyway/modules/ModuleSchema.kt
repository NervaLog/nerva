package dev.dailywombat.flyway.modules

abstract class ModuleSchema {
    abstract val name: String

    fun migrationPath() =
        "$DefaultMigrationPrefix/$name"

    companion object {
        const val DefaultMigrationPrefix = "db/migrate"
    }
}