package dev.template.app.auth

import com.auth0.jwt.JWT
import com.auth0.jwt.algorithms.Algorithm
import com.auth0.jwt.exceptions.JWTVerificationException
import dev.template.iam.UserInfo
import org.http4k.core.Request
import org.http4k.core.Response
import org.http4k.core.cookie.Cookie
import org.http4k.core.cookie.SameSite
import org.http4k.core.cookie.cookie
import org.http4k.core.cookie.cookies
import java.time.Duration
import java.time.Instant
import java.util.*

/**
 * JWT-based session management.
 *
 * Encodes user info into a signed JWT stored in an HttpOnly cookie.
 * The JWT contains user ID, email, and primary org details.
 */
object JwtSession {
    private const val ISSUER = "creator-vortex"
    private const val COOKIE_NAME = "cv_session"
    private val SESSION_DURATION: Duration = Duration.ofDays(7)

    /**
     * Claims extracted from a valid JWT session.
     */
    data class Claims(
        val userId: UUID,
        val email: String,
        val orgId: UUID,
        val orgName: String,
        val orgSlug: String,
        val role: String
    )

    /**
     * Encode UserInfo into a signed JWT token.
     */
    fun encode(userInfo: UserInfo, secret: String): String {
        val algorithm = Algorithm.HMAC256(secret)
        val primaryOrg = userInfo.org_membership.firstOrNull()
            ?: throw IllegalArgumentException("User has no org membership")

        return JWT.create()
            .withIssuer(ISSUER)
            .withSubject(userInfo.id.toString())
            .withClaim("email", userInfo.email)
            .withClaim("org_id", primaryOrg.orgs.id.toString())
            .withClaim("org_name", primaryOrg.orgs.name)
            .withClaim("org_slug", primaryOrg.orgs.slug.value)
            .withClaim("role", primaryOrg.effectiveRole.name)
            .withIssuedAt(Instant.now())
            .withExpiresAt(Instant.now().plus(SESSION_DURATION))
            .sign(algorithm)
    }

    /**
     * Decode and verify a JWT token, returning Claims if valid.
     */
    fun decode(token: String, secret: String): Claims? {
        return try {
            val algorithm = Algorithm.HMAC256(secret)
            val verifier = JWT.require(algorithm)
                .withIssuer(ISSUER)
                .build()

            val decoded = verifier.verify(token)

            Claims(
                userId = UUID.fromString(decoded.subject),
                email = decoded.getClaim("email").asString(),
                orgId = UUID.fromString(decoded.getClaim("org_id").asString()),
                orgName = decoded.getClaim("org_name").asString(),
                orgSlug = decoded.getClaim("org_slug").asString(),
                role = decoded.getClaim("role").asString()
            )
        } catch (e: JWTVerificationException) {
            null
        } catch (e: IllegalArgumentException) {
            null
        }
    }

    /**
     * Create a session cookie containing the JWT.
     */
    fun createSessionCookie(userInfo: UserInfo, secret: String): Cookie {
        val token = encode(userInfo, secret)
        return Cookie(
            name = COOKIE_NAME,
            value = token,
            maxAge = SESSION_DURATION.seconds,
            path = "/",
            httpOnly = true,
            sameSite = SameSite.Lax
        )
    }

    /**
     * Add session cookie to response.
     */
    fun createSession(response: Response, userInfo: UserInfo, secret: String): Response {
        return response.cookie(createSessionCookie(userInfo, secret))
    }

    /**
     * Extract and validate Claims from request.
     * Checks Authorization header (Bearer token) first, then falls back to cookie.
     */
    fun getClaims(request: Request, secret: String): Claims? {
        // Try Bearer token first (for mobile/API clients)
        val authHeader = request.header("Authorization")
        if (authHeader != null && authHeader.startsWith("Bearer ")) {
            val token = authHeader.removePrefix("Bearer ")
            val claims = decode(token, secret)
            if (claims != null) return claims
        }

        // Fall back to cookie (for web clients)
        val sessionCookie = request.cookies().find { it.name == COOKIE_NAME }
            ?: return null
        return decode(sessionCookie.value, secret)
    }

    /**
     * Create a cookie that clears the session.
     */
    fun clearSessionCookie(): Cookie {
        return Cookie(
            name = COOKIE_NAME,
            value = "",
            maxAge = 0,
            path = "/"
        )
    }

    /**
     * Clear session from response.
     */
    fun clearSession(response: Response): Response {
        return response.cookie(clearSessionCookie())
    }
}
