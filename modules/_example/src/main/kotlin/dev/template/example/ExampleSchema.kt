package dev.template.example

import dev.dailywombat.flyway.modules.Entity
import dev.dailywombat.flyway.modules.ModuleSchema

/**
 * Example module schema - copy this for new domain modules.
 *
 * Each module owns a PostgreSQL schema and defines:
 * - Tables
 * - Stored functions
 * - Custom error codes
 * - Enums (synced to Kotlin)
 */
object ExampleSchema : ModuleSchema() {

    override val name = "example"

    override val tables = listOf(
        Entity.table("things", "Example entities"),
    )

    override val storedFunctions = listOf(
        Entity.storedFunction("create_thing", "Creates a new thing"),
    )

    // Reference stored functions by name
    val CreateThing = storedFunctions.first { it.name == "create_thing" }
}
