package dev.template.example_app

import dev.dailywombat.flyway.FlywayConfig
import dev.dailywombat.postgrest.PostgRestConfig
import org.http4k.config.Environment
import org.http4k.config.EnvironmentKey
import org.http4k.core.Uri
import org.http4k.lens.int
import org.http4k.lens.string
import org.http4k.lens.uri

/**
 * Application configuration loaded from environment.
 */
data class ExampleConfig(
    val servicePort: Int,
    val postgrest: PostgRestConfig,
    val flyway: FlywayConfig,
) {
    companion object {
        private val SERVICE_PORT = EnvironmentKey.int().defaulted("SERVICE_PORT", 8080)
        private val POSTGREST_URL = EnvironmentKey.uri().required("POSTGREST_URL")

        private val DB_HOST = EnvironmentKey.string().defaulted("DB_HOST", "localhost")
        private val DB_PORT = EnvironmentKey.int().defaulted("DB_PORT", 5432)
        private val DB_NAME = EnvironmentKey.string().defaulted("DB_NAME", "dev")
        private val DB_USER = EnvironmentKey.string().defaulted("DB_USER", "postgres")
        private val DB_PASSWORD = EnvironmentKey.string().defaulted("DB_PASSWORD", "postgres")

        fun of(env: Environment) = ExampleConfig(
            servicePort = SERVICE_PORT(env),
            postgrest = PostgRestConfig(POSTGREST_URL(env)),
            flyway = FlywayConfig(
                host = DB_HOST(env),
                port = DB_PORT(env),
                database = DB_NAME(env),
                username = DB_USER(env),
                password = DB_PASSWORD(env),
            ),
        )
    }
}
