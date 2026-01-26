package dev.template.iam_stytch.discovery.actions

import arrow.core.raise.context.Raise
import arrow.core.raise.context.withError
import com.stytch.java.b2b.StytchB2BClient
import dev.template.iam_stytch.IamStytchError
import dev.dailywombat.stytch.IntermediateSessionToken
import dev.dailywombat.stytch.api.Discovery
import dev.dailywombat.utils.Seeds
import dev.dailywombat.utils.Slug

internal object CreateStytchOrganization {

    context(
        _: StytchB2BClient,
        _: Raise<IamStytchError>)
    operator fun invoke(
        token: IntermediateSessionToken
    ) = withError(IamStytchError::Stytch) {
        val slug = Slug.of(Seeds.freshBase32Id(32))
        Discovery.organizationsCreate(
            token,
            orgName = "org-${slug.value}",
            orgSlug = slug
        )
    }
}