package dev.template.app.endpoints

import dev.template.app.App
import dev.template.app.auth.SessionUserKey
import dev.template.app.views.HomePage
import org.http4k.core.HttpHandler
import org.http4k.core.Response
import org.http4k.core.Status.Companion.OK
import org.http4k.core.with

/**
 * Home page - protected, requires authentication.
 * Expects SessionFilter + AuthGuardFilter to have run first.
 */
val Home: HttpHandler = { request ->
    val user = SessionUserKey(request)!!
    Response(OK).with(App.ViewLens of HomePage(user = user))
}
