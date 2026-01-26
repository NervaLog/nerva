package dev.template.app.views

import dev.template.app.auth.SessionUser
import org.http4k.template.ViewModel

data class HomePage(
    val user: SessionUser,
    val currentPath: String = "/"
) : ViewModel {
    // Pass through user info to the template for AppShell
    val userInitial: String get() = user.initial
    val userName: String get() = user.name
    val userEmail: String get() = user.email
    val orgInitial: String get() = user.orgInitial
    val orgName: String get() = user.orgName
}
