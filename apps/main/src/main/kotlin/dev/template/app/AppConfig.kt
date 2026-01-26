package dev.template.app

import dev.dailywombat.flyway.FlywayConfig
import dev.dailywombat.postgrest.PostgRestConfig
import dev.dailywombat.stytch.StytchConfig
import org.http4k.config.Environment
import org.http4k.config.EnvironmentKey
import org.http4k.core.Uri
import org.http4k.lens.int
import org.http4k.lens.string
import org.http4k.lens.uri
import dev.dailywombat.cache.config.GeminiConfig

data class AppConfig(
    val servicePort: Int,
    val healthPort: Int,
    val origin: Uri,
    val jwtSecret: String,
    val flyway: FlywayConfig,
    val postgrest: PostgRestConfig,
    val stytch: StytchConfig,
    val gemini: GeminiConfig,
) {
    companion object {
        fun of(env: Environment): AppConfig {
            val int = EnvironmentKey.int()
            val uri = EnvironmentKey.uri()
            val string = EnvironmentKey.string()

            return AppConfig(
                servicePort = int.required("SERVICE_PORT")(env),
                healthPort = int.required("HEALTH_PORT")(env),
                origin = uri.required("ORIGIN")(env),
                jwtSecret = string.required("JWT_SECRET")(env),
                flyway = FlywayConfig(
                    host = string.required("FLYWAY_HOST")(env),
                    port = int.required("FLYWAY_PORT")(env),
                    database = string.required("FLYWAY_DB")(env),
                    username = string.required("FLYWAY_USER")(env),
                    password = string.required("FLYWAY_PASSWORD")(env),
                ),
                postgrest = PostgRestConfig(
                    uri.required("PG_REST_URL")(env)
                ),
                stytch = StytchConfig(
                    projectId = string.required("STYTCH_PROJECT_ID")(env),
                    secret = string.required("STYTCH_SECRET")(env),
                    publicToken = string.required("STYTCH_PUBLIC_TOKEN")(env),
                    publicBaseUrl = string.required("STYTCH_PUBLIC_BASE_URL")(env),
                ),
                gemini = GeminiConfig(
                    apiKey = string.required("GEMINI_API_KEY")(env)
                )
            )
        }
    }
}

