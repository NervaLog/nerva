package dev.nerva.nerva.auth

import arrow.core.raise.either
import dev.dailywombat.postgrest.PostgRestClient
import dev.nerva.nerva.actions.ApiKeyValidation
import dev.nerva.nerva.actions.ValidateApiKey
import org.http4k.core.Filter
import org.http4k.core.Response
import org.http4k.core.Status
import org.http4k.lens.RequestKey
import java.util.*

data class AuthenticatedOrg(
    val orgId: UUID,
    val keyId: UUID,
    val scopes: List<String>
)

/**
 * RequestKey lens for AuthenticatedOrg stored in request context.
 * Use this to extract the authenticated org from any request.
 */
val AuthenticatedOrgKey = RequestKey.optional<AuthenticatedOrg>("authenticatedOrg")

/**
 * Filter that extracts Bearer token and validates it as an API key.
 * Injects AuthenticatedOrg into request context if valid.
 */
fun ApiKeyAuthFilter(pgRest: PostgRestClient): Filter = Filter { next ->
    { request ->
        val authHeader = request.header("Authorization")

        if (authHeader == null || !authHeader.startsWith("Bearer ")) {
            Response(Status.UNAUTHORIZED)
                .header("WWW-Authenticate", "Bearer")
                .body("""{"error": "missing_authorization"}""")
        } else {
            val apiKey = authHeader.removePrefix("Bearer ")

            val validation = either {
                context(pgRest) {
                    ValidateApiKey(apiKey)
                }
            }

            when (val result = validation.getOrNull()) {
                is ApiKeyValidation.Valid -> {
                    val authedOrg = AuthenticatedOrg(
                        orgId = result.orgId,
                        keyId = result.keyId,
                        scopes = result.scopes
                    )
                    next(AuthenticatedOrgKey(authedOrg, request))
                }
                is ApiKeyValidation.Invalid -> {
                    Response(Status.UNAUTHORIZED)
                        .body("""{"error": "${result.error}"}""")
                }
                null -> {
                    Response(Status.INTERNAL_SERVER_ERROR)
                        .body("""{"error": "auth_check_failed"}""")
                }
            }
        }
    }
}
