package dev.template.iam_stytch.discovery.models

import dev.template.iam_stytch.DiscoveryRequestToken
import dev.dailywombat.stytch.Pkce
import dev.dailywombat.stytch.RequestId
import org.http4k.core.Uri

data class DiscoveryFingerprints(
    val verifier: Pkce.CodeVerifier,
    val codeChallenge: Pkce.CodeChallenge,
    val token: DiscoveryRequestToken,
    val redirectTo: Uri,
    val requestId: RequestId? = null,
)