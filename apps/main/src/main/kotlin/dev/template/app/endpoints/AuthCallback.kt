package dev.template.app.endpoints

import arrow.core.raise.context.either
import com.stytch.java.b2b.StytchB2BClient
import dev.template.iam_stytch.DiscoveryRequestToken
import dev.template.iam_stytch.discovery.flows.CompleteDiscoveryCallback
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.stytch.Stytch
import dev.dailywombat.stytch.StytchRedirectToken
import io.github.oshai.kotlinlogging.KotlinLogging
import dev.template.app.App
import dev.template.app.AppConfig
import dev.template.app.auth.Session
import dev.template.app.views.LoginPage
import org.http4k.core.Method.GET
import org.http4k.core.Response
import org.http4k.core.Status.Companion.OK
import org.http4k.core.Status.Companion.SEE_OTHER
import org.http4k.core.with
import org.http4k.routing.RoutingHttpHandler
import org.http4k.routing.bind
import org.http4k.routing.routes

private val logger = KotlinLogging.logger("auth-callback")

/**
 * Handles the callback from Stytch after user authenticates (magic link or OAuth).
 *
 * GET /auth/callback?token=...&stytch_token_type=...&discovery_request_token=...
 */
context(config: AppConfig, stytch: StytchB2BClient, postgrest: PostgRestClient)
fun AuthCallback(): RoutingHttpHandler = routes(
    "/callback" bind GET to { request ->
        // Parse the Stytch redirect token (includes token value and type)
        val stytchRedirectToken = StytchRedirectToken(request)
        val discoveryToken = Stytch.OpaqueTokenLens(request)

        logger.info { "Processing auth callback, token type: ${stytchRedirectToken.type}" }

        either {
            with(stytch) {
                with(postgrest) {
                    CompleteDiscoveryCallback(
                        discoveryToken = DiscoveryRequestToken(discoveryToken),
                        stytchToken = stytchRedirectToken
                    )
                }
            }
        }.fold(
            ifLeft = { error ->
                logger.error { "Auth callback failed: $error" }
                Response(OK).with(
                    App.ViewLens of LoginPage(
                        error = "Authentication failed. Please try again."
                    )
                )
            },
            ifRight = { userInfo ->
                logger.info { "Auth successful for ${userInfo.email}" }
                Session.createSession(
                    Response(SEE_OTHER).header("Location", "/"),
                    userInfo,
                    config.jwtSecret
                )
            }
        )
    }
)
