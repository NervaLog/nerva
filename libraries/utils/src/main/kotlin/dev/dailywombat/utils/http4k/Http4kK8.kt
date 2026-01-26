package dev.dailywombat.utils.http4k

import io.opentelemetry.api.OpenTelemetry
import org.http4k.config.Environment
import org.http4k.core.*
import org.http4k.filter.OpenTelemetryTracing
import org.http4k.filter.ServerFilters
import org.http4k.k8s.Http4kK8sServer
import org.http4k.k8s.asK8sServer
import org.http4k.k8s.health.Health
import org.http4k.k8s.health.ReadinessCheck
import org.http4k.routing.RoutingHttpHandler
import org.http4k.routing.bind
import org.http4k.server.Undertow

object Http4kK8 {

    /**
     * Mainly useful to filter log events.
     * We _don't_ want to know every time K8 hits a readiness or liveness check.
     *
     * @see [org.http4k.k8s.health.Health]
     */
    val K8ProbePaths = listOf(
        "/liveness",
        "/readiness"
    )

    /**
     * @param structuredLoggingFilter @see [LogEvent]
     * @param boundaryExceptionFilter @see [BoundaryExceptionFilter]
     */
    fun buildK8Server(
        structuredLoggingFilter: Filter,
        boundaryExceptionFilter: Filter,
        telemetryFilter: Filter = ServerFilters.OpenTelemetryTracing(OpenTelemetry.noop()),
        routes: RoutingHttpHandler,
        env: Environment,
        checks: List<ReadinessCheck> = emptyList(),
    ): Http4kK8sServer = structuredLoggingFilter
        .then(boundaryExceptionFilter)
        .then(routes)
        .asK8sServer(
            ::Undertow,
            env = env,
            healthApp = Health(
                "/config" bind Method.GET to { Response(Status.OK).body(env.keys().toString()) },
                checks = checks
            )
        )
}