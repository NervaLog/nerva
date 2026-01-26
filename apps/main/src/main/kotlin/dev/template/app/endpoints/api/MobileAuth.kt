package dev.template.app.endpoints.api

import arrow.core.raise.context.either
import com.stytch.java.b2b.StytchB2BClient
import dev.template.app.AppConfig
import dev.template.app.auth.JwtSession
import dev.template.iam_stytch.DiscoveryRequestToken
import dev.template.iam_stytch.discovery.flows.CompleteDiscoveryCallback
import dev.template.iam_stytch.discovery.flows.OAuthProvider
import dev.template.iam_stytch.discovery.flows.RequestDiscovery
import dev.template.iam_stytch.discovery.flows.RequestOAuthDiscovery
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.stytch.Stytch
import dev.dailywombat.stytch.StytchRedirectToken
import dev.dailywombat.utils.Email
import io.github.oshai.kotlinlogging.KotlinLogging
import org.http4k.core.Body
import org.http4k.core.Method.POST
import org.http4k.core.Response
import org.http4k.core.Status.Companion.BAD_REQUEST
import org.http4k.core.Status.Companion.INTERNAL_SERVER_ERROR
import org.http4k.core.Status.Companion.OK
import org.http4k.core.Status.Companion.UNAUTHORIZED
import org.http4k.core.Uri
import org.http4k.format.Jackson
import org.http4k.routing.RoutingHttpHandler
import org.http4k.routing.bind
import org.http4k.routing.routes

private val logger = KotlinLogging.logger("mobile-auth")

/**
 * Mobile authentication API endpoints.
 *
 * These endpoints return JSON responses with JWT tokens for mobile apps
 * that can't use HttpOnly cookies.
 *
 * POST /api/v1/auth/magic-link/send     - Send magic link email
 * POST /api/v1/auth/magic-link/verify   - Verify magic link token, return JWT
 * POST /api/v1/auth/oauth/start         - Start OAuth flow, return redirect URL
 * POST /api/v1/auth/oauth/verify        - Verify OAuth callback, return JWT
 */
object MobileAuth {

    // Request/Response data classes
    data class SendMagicLinkRequest(val email: String, val deep_link_url: String)
    data class SendMagicLinkResponse(val success: Boolean, val message: String)

    data class VerifyTokenRequest(
        val discovery_token: String,
        val stytch_token: String,
        val stytch_token_type: String
    )
    data class AuthResponse(
        val token: String,
        val user: UserResponse
    )
    data class UserResponse(
        val id: String,
        val email: String,
        val org_id: String,
        val org_name: String,
        val org_slug: String,
        val role: String
    )

    data class OAuthStartRequest(val provider: String, val redirect_url: String)
    data class OAuthStartResponse(val oauth_url: String, val discovery_token: String)

    data class ErrorResponse(val error: String, val message: String)

    // Lenses
    private val sendMagicLinkRequestLens = Jackson.autoBody<SendMagicLinkRequest>().toLens()
    private val sendMagicLinkResponseLens = Jackson.autoBody<SendMagicLinkResponse>().toLens()
    private val verifyTokenRequestLens = Jackson.autoBody<VerifyTokenRequest>().toLens()
    private val authResponseLens = Jackson.autoBody<AuthResponse>().toLens()
    private val oauthStartRequestLens = Jackson.autoBody<OAuthStartRequest>().toLens()
    private val oauthStartResponseLens = Jackson.autoBody<OAuthStartResponse>().toLens()
    private val errorResponseLens = Jackson.autoBody<ErrorResponse>().toLens()

    context(config: AppConfig, stytch: StytchB2BClient, postgrest: PostgRestClient)
    operator fun invoke(): RoutingHttpHandler = routes(
        "/magic-link/send" bind POST to { request ->
            val body = try {
                sendMagicLinkRequestLens(request)
            } catch (e: Exception) {
                return@to errorResponse(BAD_REQUEST, "invalid_request", "Invalid request body")
            }

            if (!isValidEmail(body.email)) {
                return@to errorResponse(BAD_REQUEST, "invalid_email", "Invalid email address")
            }

            val redirectTo = Uri.of(body.deep_link_url)

            either {
                with(stytch) {
                    with(postgrest) {
                        RequestDiscovery(
                            email = Email(body.email),
                            redirectTo = redirectTo
                        )
                    }
                }
            }.fold(
                ifLeft = { error ->
                    logger.error { "Magic link send failed: $error" }
                    errorResponse(INTERNAL_SERVER_ERROR, "send_failed", "Failed to send magic link")
                },
                ifRight = {
                    logger.info { "Magic link sent to ${body.email}" }
                    sendMagicLinkResponseLens(
                        SendMagicLinkResponse(success = true, message = "Magic link sent"),
                        Response(OK)
                    )
                }
            )
        },

        "/magic-link/verify" bind POST to { request ->
            val body = try {
                verifyTokenRequestLens(request)
            } catch (e: Exception) {
                return@to errorResponse(BAD_REQUEST, "invalid_request", "Invalid request body")
            }

            verifyToken(body)
        },

        "/oauth/start" bind POST to { request ->
            val body = try {
                oauthStartRequestLens(request)
            } catch (e: Exception) {
                return@to errorResponse(BAD_REQUEST, "invalid_request", "Invalid request body")
            }

            val provider = when (body.provider.lowercase()) {
                "google" -> OAuthProvider.GOOGLE
                "microsoft" -> OAuthProvider.MICROSOFT
                else -> return@to errorResponse(BAD_REQUEST, "invalid_provider", "Unknown OAuth provider")
            }

            val redirectTo = Uri.of(body.redirect_url)

            either {
                with(postgrest) {
                    RequestOAuthDiscovery(
                        provider = provider,
                        redirectTo = redirectTo,
                        stytchConfig = config.stytch
                    )
                }
            }.fold(
                ifLeft = { error ->
                    logger.error { "OAuth start failed: $error" }
                    errorResponse(INTERNAL_SERVER_ERROR, "oauth_failed", "Failed to start OAuth flow")
                },
                ifRight = { result ->
                    logger.info { "OAuth URL generated for ${body.provider}" }
                    oauthStartResponseLens(
                        OAuthStartResponse(
                            oauth_url = result.redirectUrl.toString(),
                            discovery_token = result.discoveryRequest.token.value
                        ),
                        Response(OK)
                    )
                }
            )
        },

        "/oauth/verify" bind POST to { request ->
            val body = try {
                verifyTokenRequestLens(request)
            } catch (e: Exception) {
                return@to errorResponse(BAD_REQUEST, "invalid_request", "Invalid request body")
            }

            verifyToken(body)
        }
    )

    context(config: AppConfig, stytch: StytchB2BClient, postgrest: PostgRestClient)
    private fun verifyToken(body: VerifyTokenRequest): Response {
        val tokenType = try {
            StytchRedirectToken.Companion.TokenType.valueOf(body.stytch_token_type)
        } catch (e: IllegalArgumentException) {
            return errorResponse(BAD_REQUEST, "invalid_token_type", "Unknown token type: ${body.stytch_token_type}")
        }

        val stytchRedirectToken = StytchRedirectToken(
            value = body.stytch_token,
            type = tokenType
        )
        val discoveryToken = DiscoveryRequestToken(body.discovery_token)

        return either {
            with(stytch) {
                with(postgrest) {
                    CompleteDiscoveryCallback(
                        discoveryToken = discoveryToken,
                        stytchToken = stytchRedirectToken
                    )
                }
            }
        }.fold(
            ifLeft = { error ->
                logger.error { "Token verification failed: $error" }
                errorResponse(UNAUTHORIZED, "verification_failed", "Token verification failed")
            },
            ifRight = { userInfo ->
                logger.info { "Mobile auth successful for ${userInfo.email}" }
                val jwt = JwtSession.encode(userInfo, config.jwtSecret)
                val claims = JwtSession.decode(jwt, config.jwtSecret)!!

                authResponseLens(
                    AuthResponse(
                        token = jwt,
                        user = UserResponse(
                            id = claims.userId.toString(),
                            email = claims.email,
                            org_id = claims.orgId.toString(),
                            org_name = claims.orgName,
                            org_slug = claims.orgSlug,
                            role = claims.role
                        )
                    ),
                    Response(OK)
                )
            }
        )
    }

    private fun errorResponse(status: org.http4k.core.Status, error: String, message: String): Response =
        errorResponseLens(ErrorResponse(error, message), Response(status))

    private fun isValidEmail(email: String): Boolean =
        email.contains("@") && email.contains(".")
}
