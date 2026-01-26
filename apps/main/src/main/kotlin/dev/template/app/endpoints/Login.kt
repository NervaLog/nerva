package dev.template.app.endpoints

import arrow.core.raise.context.either
import com.stytch.java.b2b.StytchB2BClient
import dev.template.iam.UserInfo
import dev.template.iam_stytch.discovery.flows.OAuthProvider
import dev.template.iam_stytch.discovery.flows.RequestDiscovery
import dev.template.iam_stytch.discovery.flows.RequestOAuthDiscovery
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.utils.Email
import io.github.oshai.kotlinlogging.KotlinLogging
import dev.template.app.App
import dev.template.app.AppConfig
import dev.template.app.auth.Session
import dev.template.app.views.LoginPage
import org.http4k.core.Body
import org.http4k.core.Method.GET
import org.http4k.core.Method.POST
import org.http4k.core.Response
import org.http4k.core.Status.Companion.INTERNAL_SERVER_ERROR
import org.http4k.core.Status.Companion.OK
import org.http4k.core.Status.Companion.SEE_OTHER
import org.http4k.core.Uri
import org.http4k.core.with
import org.http4k.lens.FormField
import org.http4k.lens.Validator
import org.http4k.lens.webForm
import org.http4k.routing.RoutingHttpHandler
import org.http4k.routing.bind
import org.http4k.routing.routes
import java.util.UUID

private val logger = KotlinLogging.logger("login")

private val emailField = FormField.required("email")
private val formLens = Body.webForm(Validator.Feedback, emailField).toLens()

/**
 * Login endpoint handling authentication flows.
 *
 * GET  /login           - Renders the login form
 * GET  /login/google    - Initiates Google OAuth flow (redirects to Google)
 * POST /login/send-link - Sends magic link email via Stytch
 * POST /login/demo      - Creates demo session (for development)
 */
context(config: AppConfig, stytch: StytchB2BClient, postgrest: PostgRestClient)
fun Login(): RoutingHttpHandler = routes(
    "/" bind GET to {
        Response(OK).with(App.ViewLens of LoginPage())
    },

    "/google" bind GET to {
        val redirectTo = Uri.of("${config.origin}/auth/callback")

        either {
            with(postgrest) {
                RequestOAuthDiscovery(
                    provider = OAuthProvider.GOOGLE,
                    redirectTo = redirectTo,
                    stytchConfig = config.stytch
                )
            }
        }.fold(
            ifLeft = { error ->
                logger.error { "Google OAuth initiation failed: $error" }
                Response(INTERNAL_SERVER_ERROR).body("Failed to initiate Google login")
            },
            ifRight = { result ->
                logger.info { "Redirecting to Google OAuth" }
                Response(SEE_OTHER).header("Location", result.redirectUrl.toString())
            }
        )
    },

    "/send-link" bind POST to { request ->
        val form = formLens(request)
        val email = emailField(form)

        if (form.errors.isNotEmpty()) {
            Response(OK).with(
                App.ViewLens of LoginPage(
                    email = email,
                    error = "Please enter a valid email address"
                )
            )
        } else {
            val redirectTo = Uri.of("${config.origin}/auth/callback")

            either {
                with(stytch) {
                    with(postgrest) {
                        RequestDiscovery(
                            email = Email(email),
                            redirectTo = redirectTo
                        )
                    }
                }
            }.fold(
                ifLeft = { error ->
                    logger.error { "Magic link request failed: $error" }
                    Response(OK).with(
                        App.ViewLens of LoginPage(
                            email = email,
                            error = "Failed to send magic link. Please try again."
                        )
                    )
                },
                ifRight = {
                    logger.info { "Magic link sent to $email" }
                    Response(OK).with(
                        App.ViewLens of LoginPage(
                            email = email,
                            sent = true
                        )
                    )
                }
            )
        }
    },

    "/demo" bind POST to {
        logger.info { "Creating demo session" }
        Session.createSession(
            Response(SEE_OTHER).header("Location", "/"),
            createDemoUserInfo(),
            config.jwtSecret
        )
    }
)

/**
 * Logout endpoint - clears session and redirects to login.
 */
fun Logout(): RoutingHttpHandler = routes(
    "/" bind GET to {
        Session.clearSession(
            Response(SEE_OTHER).header("Location", "/login")
        )
    }
)

/**
 * Creates a demo UserInfo for testing without Stytch.
 * This simulates what would come from the real auth flow.
 */
private fun createDemoUserInfo(): UserInfo {
    val demoUserId = UUID.fromString("00000000-0000-0000-0000-000000000001")
    val demoOrgId = UUID.fromString("00000000-0000-0000-0000-000000000002")

    return UserInfo(
        id = demoUserId,
        email = "demo@example.com",
        status = dev.template.iam.model.UserStatus.active,
        org_membership = listOf(
            UserInfo.OrgMembershipInfo(
                role = dev.template.iam.model.OrgRole.owner,
                is_primary_owner = true,
                orgs = UserInfo.OrgInfo(
                    id = demoOrgId,
                    name = "Demo Organization",
                    slug = dev.dailywombat.utils.Slug("demo-org")
                )
            )
        )
    )
}
