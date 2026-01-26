@file:Suppress("PropertyName")

package dev.template.iam_stytch.discovery.models

import dev.template.iam_stytch.DiscoveryRequestToken
import dev.dailywombat.postgrest.PostgRestCompanion
import dev.dailywombat.postgrest.PostgRestEntity
import dev.dailywombat.stytch.Pkce
import dev.dailywombat.stytch.RequestId
import dev.dailywombat.utils.Email
import dev.dailywombat.utils.Seeds
import org.http4k.core.Uri
import org.http4k.format.Jackson
import org.http4k.lens.BiDiBodyLens
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.*

data class DiscoveryRequest(
    override val id: UUID = Seeds.freshUuid7(),

    val token: DiscoveryRequestToken = DiscoveryRequestToken(),
    val redirect_to: Uri,

    override val created_at: Instant = Instant.now(),
    val expires_at: Instant = Instant.now().plus(10, ChronoUnit.MINUTES),

    val email: Email? = null,
    val first_name: String? = null,

    val request_id: RequestId? = null,
    val provider: String? = null,

    val verifier: Pkce.CodeVerifier,
    val code_challenge: Pkce.CodeChallenge,

    val leased_at: Instant? = null,
    val lease_expires_at: Instant? = null,
    val lease_owner: String? = null,

    val consumed_at: Instant? = null,
) : PostgRestEntity<DiscoveryRequest> {

    companion object : PostgRestCompanion<DiscoveryRequest> {
        override val lens: BiDiBodyLens<DiscoveryRequest> = Jackson.autoBody<DiscoveryRequest>().toLens()
        override val listLens = Jackson.autoBody<List<DiscoveryRequest>>().toLens()

        /** Create for magic link discovery (email known upfront) */
        fun forMagicLink(
            email: Email,
            firstName: String?,
            drf: DiscoveryFingerprints
        ) = DiscoveryRequest(
            email = email,
            first_name = firstName,
            verifier = drf.verifier,
            code_challenge = drf.codeChallenge,
            token = drf.token,
            redirect_to = drf.redirectTo,
            request_id = drf.requestId,
            provider = "magic_link",
        )

        /** Create for OAuth discovery (email provided by OAuth callback) */
        fun forOAuth(
            provider: String,
            drf: DiscoveryFingerprints
        ) = DiscoveryRequest(
            verifier = drf.verifier,
            code_challenge = drf.codeChallenge,
            token = drf.token,
            redirect_to = drf.redirectTo,
            provider = provider,
        )
    }
}