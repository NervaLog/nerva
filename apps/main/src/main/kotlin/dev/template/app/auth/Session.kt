package dev.template.app.auth

import dev.template.iam.UserInfo
import org.http4k.core.Filter
import org.http4k.core.Request
import org.http4k.core.Response
import org.http4k.core.Status.Companion.SEE_OTHER
import org.http4k.lens.RequestKey

/**
 * RequestKey lens for SessionUser stored in request context.
 * Use this to extract the authenticated user from any request.
 */
val SessionUserKey = RequestKey.optional<SessionUser>("sessionUser")

/**
 * Filter that extracts JWT from cookie and injects SessionUser into request context.
 * Apply this filter to routes that need session info (even if not requiring auth).
 */
fun SessionFilter(jwtSecret: String): Filter = Filter { next ->
    { request ->
        val claims = JwtSession.getClaims(request, jwtSecret)
        val enrichedRequest = if (claims != null) {
            val user = SessionUser(
                id = claims.userId.toString(),
                email = claims.email,
                name = claims.email.substringBefore("@"),
                orgId = claims.orgId.toString(),
                orgName = claims.orgName
            )
            SessionUserKey(user, request)
        } else {
            request
        }
        next(enrichedRequest)
    }
}

/**
 * Filter that requires authentication. Redirects to /login if no session.
 * Must be applied AFTER SessionFilter.
 */
fun AuthGuardFilter(): Filter = Filter { next ->
    { request ->
        if (SessionUserKey(request) != null) {
            next(request)
        } else {
            Response(SEE_OTHER).header("Location", "/login")
        }
    }
}

/**
 * Session operations for creating/clearing JWT cookies.
 */
object Session {
    fun createSession(response: Response, userInfo: UserInfo, jwtSecret: String): Response {
        return JwtSession.createSession(response, userInfo, jwtSecret)
    }

    fun clearSession(response: Response): Response {
        return JwtSession.clearSession(response)
    }
}

/**
 * Represents an authenticated user session.
 */
data class SessionUser(
    val id: String,
    val email: String,
    val name: String,
    val orgId: String,
    val orgName: String
) {
    val initial: String get() = name.firstOrNull()?.uppercase() ?: "U"
    val orgInitial: String get() = orgName.firstOrNull()?.uppercase() ?: "O"
}
