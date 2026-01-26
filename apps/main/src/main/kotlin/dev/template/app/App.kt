package dev.template.app

import arrow.core.Either.Companion.catch
import arrow.core.raise.context.bind
import arrow.core.raise.context.either
import com.stytch.java.b2b.StytchB2BClient
import dev.dailywombat.devruntime.DevPostgresContainer
import dev.dailywombat.devruntime.DevPostgrestContainer
import dev.dailywombat.devruntime.DevRuntime
import dev.dailywombat.flyway.migration.FlywayMigrator
import dev.dailywombat.flyway.modules.DatabaseModules
import dev.template.iam.IamSchema
import dev.template.iam_stytch.IamStytchSchema
import dev.dailywombat.cache.CacheSchema
import dev.nerva.nerva.NervaSchema
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.Postgrest
import dev.dailywombat.stytch.Stytch
import dev.dailywombat.utils.http4k.LogEvent
import io.github.oshai.kotlinlogging.KotlinLogging
import dev.template.app.auth.AuthGuardFilter
import dev.template.app.auth.SessionFilter
import dev.template.app.endpoints.AuthCallback
import dev.template.app.endpoints.Home
import dev.template.app.endpoints.Login
import dev.template.app.endpoints.Logout
import dev.template.app.endpoints.api.GetSummary
import dev.template.app.endpoints.api.MobileAuth
import dev.template.app.endpoints.api.events.IngestEvents
import dev.nerva.nerva.auth.ApiKeyAuthFilter
import dev.dailywombat.cache.config.GeminiConfig
import org.http4k.config.Environment
import org.http4k.config.Environment.Companion.ENV
import org.http4k.config.Environment.Companion.from
import org.http4k.config.Environment.Companion.fromResource
import org.http4k.core.*
import org.http4k.core.Status.Companion.OK
import org.http4k.k8s.asK8sServer
import org.http4k.k8s.health.Completed
import org.http4k.k8s.health.Health
import org.http4k.k8s.health.ReadinessCheck
import org.http4k.k8s.health.ReadinessCheckResult
import org.http4k.routing.ResourceLoader.Companion.Classpath
import org.http4k.routing.bind
import org.http4k.routing.routes
import org.http4k.routing.static
import org.http4k.server.Undertow
import org.http4k.template.PebbleTemplates
import org.http4k.template.viewModel

object App {

    @JvmStatic
    fun main(args: Array<String>) {
        val devMode = System.getenv("DEV_MODE")?.toBoolean() == true

        val result = either {
            val baseEnv = ENV overrides catch { fromResource(".env") }.bind()

            // In dev mode, start containers and override DB configs
            val (env, devRuntime) = if (devMode) {
                Logger.atInfo { message = "Starting in DEV_MODE - spinning up containers..." }
                val modules = listOf(IamSchema, IamStytchSchema, CacheSchema, NervaSchema)
                val runtime = DevRuntime.start(
                    DevPostgresContainer(modules),
                    DevPostgrestContainer(modules)
                )
                val postgres = runtime.get<DevPostgresContainer>()
                val postgrest = runtime.get<DevPostgrestContainer>()

                // Override the flyway and postgrest configs with container values
                val devOverrides = Environment.from(
                    "FLYWAY_HOST" to "localhost",
                    "FLYWAY_PORT" to postgres.flywayConfig.port.toString(),
                    "FLYWAY_DB" to postgres.flywayConfig.database,
                    "FLYWAY_USER" to postgres.flywayConfig.username,
                    "FLYWAY_PASSWORD" to postgres.flywayConfig.password,
                    "PG_REST_URL" to postgrest.config.baseUri.toString(),
                )
                (devOverrides overrides baseEnv) to runtime
            } else {
                baseEnv to null
            }

            val config = AppConfig.of(env)

            // Only run migrations manually if not in dev mode (DevRuntime already ran them)
            if (devRuntime == null) {
                val modules = DatabaseModules.discoverModules().bind()
                FlywayMigrator.migrate(config.flyway, modules).bind()
            }

            // Create clients
            val stytchClient = Stytch.b2bClient(config.stytch)
            val postgrestClient = Postgrest.client(config.postgrest)

            // Build routes with config and clients
            val app = with(config) {
                with(stytchClient) {
                    with(postgrestClient) {
                        buildRoutes()
                    }
                }
            }

            /**
             * @param env - SERVICE_PORT and HEALTH_PORT are extracted
             * by the server directly from the env.
             */
            val server = LogEvent.StructuredLoggingFilter("app").then(app).asK8sServer(
                ::Undertow,
                env = env,
                healthApp = Health(
                    "/config" bind Method.GET to { Response(OK).body(env.keys().toString()) },
                    checks = listOf<ReadinessCheck>(object : ReadinessCheck {
                        override val name = "Is PostgRest Up"
                        override fun invoke(): ReadinessCheckResult = Completed(name)
                    })
                )
            )

            server.start()
            Logger.atInfo {
                message = "Up and listening on ${config.servicePort}; origin=${config.origin}"
            }
            if (devRuntime != null) {
                Logger.atInfo { message = "PostgREST at ${config.postgrest.baseUri}" }
            }
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

    val Logger = KotlinLogging.logger("main")

    private val Renderer = PebbleTemplates().CachingClasspath()
    val ViewLens = Body.viewModel(Renderer, ContentType.TEXT_HTML).toLens()

    /**
     * Build routes with dependency injection.
     */
    context(config: AppConfig, _: StytchB2BClient, pgClient: PostgRestClient)
    fun buildRoutes() = routes(
        "/assets" bind static(Classpath("assets")),

        "/login" bind Login(),
        "/logout" bind Logout(),
        "/auth" bind AuthCallback(),

        // Public API routes
        context(pgClient, config.gemini) {
            GetSummary()
        },

        // Mobile auth API (returns JWT in response body)
        "/api/v1/auth" bind MobileAuth(),

        // Event ingestion API (API key auth)
        ApiKeyAuthFilter(pgClient).then(
            routes(
                context(pgClient) { IngestEvents() }
            )
        ),

        // Protected routes (auth required)
        SessionFilter(config.jwtSecret)
            .then(AuthGuardFilter())
            .then(
                routes(
                    "/" bind Home,
                    // Add your protected routes here
                )
            ),
    )
}

