package dev.template.example_app.endpoints

import org.http4k.core.Request
import org.http4k.core.Response
import org.http4k.core.Status.Companion.OK

/**
 * Simple health check endpoint.
 */
object HealthCheck : (Request) -> Response {
    override fun invoke(request: Request): Response =
        Response(OK).body("""{"status": "ok"}""")
}
