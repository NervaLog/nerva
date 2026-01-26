@file:Suppress("PropertyName")

package dev.dailywombat.flyway

import org.http4k.core.Uri
import org.http4k.core.query
import org.postgresql.ds.PGSimpleDataSource

data class FlywayConfig(
    val host: String,
    val port: Int,
    val database: String,
    val username: String,
    val password: String
) {
    companion object {
        /**
         * Where the `flyway_migration_history` table goes.
         */
        const val DefaultSchema = "flyway"

        /**
         * Where we install extensions, by convention.
         */
        const val ExtensionsSchema = "extensions"
    }

    val jdbcUrl = Uri.of("")
        .scheme("postgresql")
        .host("localhost")
        .port(port)
        .path("/$database")
        .query("user", username)
        .query("password", password)
        .query("sslmode", "prefer")
        .let { "jdbc:$it" }

    val dataSource =
        PGSimpleDataSource().apply { setUrl(jdbcUrl) }
}
