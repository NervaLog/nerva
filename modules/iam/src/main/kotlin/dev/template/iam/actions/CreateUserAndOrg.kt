@file:Suppress("PropertyName")

package dev.template.iam.actions

import arrow.core.raise.context.Raise
import dev.template.iam.IamSchema
import dev.template.iam.IamSchema.CreateUserAndOrg
import dev.template.iam.ProviderSubject
import dev.template.iam.UserInfo
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.RpcPost
import dev.dailywombat.postgrest.actions.Select
import dev.dailywombat.postgrest.headers.Prefer
import dev.dailywombat.utils.Email
import dev.dailywombat.utils.Slug

object CreateUserAndOrg {

    private data class Args<Provider : Enum<Provider>>(
        val p_provider: Provider,
        val p_provider_subject: String,
        val p_email: String,
        val p_first_name: String?,
        val p_org_slug: String,
    )

    /**
     *     provider ${iam.schema}.auth_provider,
     *     provider_subject text,
     *     email text,
     *     first_name text,
     *     org_slug text,
     *     role ${iam.schema}.org_role DEFAULT 'owner',
     *     is_primary_owner boolean DEFAULT true
     *
     */
    context(
        pgRest: PostgRestClient,
        _: Raise<PostgRestError>
    )
    operator fun <Provider : Enum<Provider>> invoke(
        provider: Provider,
        providerSubject: ProviderSubject,
        email: Email,
        firstName: String? = null,
        orgSlug: Slug,
    ) = context(UserInfo.lens) {
        val args = Args(
            p_provider = provider,
            p_provider_subject = providerSubject.value,
            p_email = email.value,
            p_first_name = firstName,
            p_org_slug = orgSlug.value,
        )

        pgRest(CreateUserAndOrg, RpcPost(args) {
            contentProfile(IamSchema)
            accept(Select.Accept.SingularRepresentation)
            returning(Prefer.Return.Representation)
        })
    }
}