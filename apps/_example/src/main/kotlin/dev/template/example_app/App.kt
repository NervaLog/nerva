package dev.template.example_app

import arrow.core.Either.Companion.catch
import arrow.core.raise.context.bind
import arrow.core.raise.context.either
import dev.dailywombat.flyway.migration.FlywayMigrator
import dev.dailywombat.flyway.modules.DatabaseModules
import dev.dailywombat.postgrest.Postgrest
import dev.dailywombat.utils.http4k.LogEvent
import io.github.oshai.kotlinlogging.KotlinLogging
import dev.template.example_app.endpoints.HealthCheck
import org.http4k.config.Environment.Companion.ENV
import org.http4k.config.Environment.Companion.fromResource
import org.http4k.core.Method
import org.http4k.core.Response
import org.http4k.core.Status.Companion.OK
import org.http4k.k8s.asK8sServer
import org.http4k.k8s.health.Completed
import org.http4k.k8s.health.Health
import org.http4k.k8s.health.ReadinessCheck
import org.http4k.k8s.health.ReadinessCheckResult
import org.http4k.routing.bind
import org.http4k.routing.routes
import org.http4k.server.Undertow

/**
 * Example app entry point.
 *
 * Pattern:
 * 1. Load environment config
 * 2. Discover database modules
 * 3. Run Flyway migrations
 * 4. Create clients
 * 5. Build routes
 * 6. Start K8s-compatible server
 */
object App {

    private val Logger = KotlinLogging.logger("example-app")

    @JvmStatic
    fun main(args: Array<String>) {
        val result = either {
            val env = ENV overrides catch { fromResource(".env") }.bind()
            val config = ExampleConfig.of(env)

            val modules = DatabaseModules.discoverModules().bind()
            FlywayMigrator.migrate(config.flyway, modules).bind()

            val postgrestClient = Postgrest.client(config.postgrest)

            val app = with(postgrestClient) {
                routes(
                    "/health" bind Method.GET to HealthCheck,
                    // Add your routes here
                )
            }

            val server = LogEvent.StructuredLoggingFilter("example").then(app).asK8sServer(
                ::Undertow,
                env = env,
                healthApp = Health(
                    "/config" bind Method.GET to { Response(OK).body(env.keys().toString()) },
                    checks = listOf<ReadinessCheck>(object : ReadinessCheck {
                        override val name = "PostgRest"
                        override fun invoke(): ReadinessCheckResult = Completed(name)
                    })
                )
            )

            server.start()
            Logger.atInfo { message = "Up and listening on ${config.servicePort}" }
            server.block()
        }

        result.fold(
            ifLeft = { error ->
                Logger.atError { message = "Failed to start: $error" }
                System.exit(1)
            },
            ifRight = { /* Server stopped */ }
        )
    }
}
