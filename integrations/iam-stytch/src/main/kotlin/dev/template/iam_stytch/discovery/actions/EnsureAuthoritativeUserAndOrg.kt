package dev.template.iam_stytch.discovery.actions

import arrow.core.raise.context.Raise
import arrow.core.raise.context.withError
import dev.template.iam.ProviderSubject
import dev.template.iam.actions.CreateUserAndOrg
import dev.template.iam_stytch.IamStytchError
import dev.template.iam_stytch.StytchIdentityTypes
import dev.template.iam_stytch.discovery.models.CreateOrExchangeResponse
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.utils.Email
import dev.dailywombat.utils.Slug

internal object EnsureAuthoritativeUserAndOrg {

    context(
        _: PostgRestClient,
        _: Raise<IamStytchError>
    )
    operator fun invoke(
        coe: CreateOrExchangeResponse
    ) = withError(IamStytchError::PostgRest) {
        CreateUserAndOrg(
            provider = StytchIdentityTypes.stytch_magic_link,
            providerSubject = ProviderSubject(coe.memberId),
            email = Email(coe.member.emailAddress),
            orgSlug = Slug(coe.organization!!.organizationSlug)
        )
    }
}