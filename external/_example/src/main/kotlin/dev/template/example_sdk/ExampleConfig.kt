package dev.template.example_sdk

import org.http4k.config.Environment
import org.http4k.config.EnvironmentKey
import org.http4k.lens.string

/**
 * Example SDK configuration - loaded from environment variables.
 */
data class ExampleConfig(
    val apiKey: String,
    val baseUrl: String = "https://api.example.com",
) {
    companion object {
        private val API_KEY = EnvironmentKey.string().required("EXAMPLE_API_KEY")
        private val BASE_URL = EnvironmentKey.string().defaulted("EXAMPLE_BASE_URL", "https://api.example.com")

        fun of(env: Environment) = ExampleConfig(
            apiKey = API_KEY(env),
            baseUrl = BASE_URL(env),
        )
    }
}
