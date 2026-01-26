package dev.template.app.views

import org.http4k.template.ViewModel

data class LoginPage(
    val email: String? = null,
    val error: String? = null,
    val sent: Boolean = false
) : ViewModel