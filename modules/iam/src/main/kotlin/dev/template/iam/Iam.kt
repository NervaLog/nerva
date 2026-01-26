@file:Suppress("PropertyName", "LocalVariableName")

package dev.template.iam

import arrow.core.raise.context.Raise
import dev.template.iam.IamSchema
import dev.template.iam.IamSchema.CreateUserAndOrg
import dev.template.iam.UserInfo.Companion.lens
import dev.template.iam.model.OrgMembership.Companion.Role
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.RpcPost
import dev.dailywombat.postgrest.actions.Select
import dev.dailywombat.utils.Email
import dev.dailywombat.utils.Slug

object Iam {

    context(
        pgRest: PostgRestClient,
        _: Raise<PostgRestError>
    )
    @Deprecated(
        message = "there's no reason to have two :)",
        replaceWith = ReplaceWith("CreateUserAndOrg")
    )
    fun <Provider : Enum<Provider>> createUserAndOrgWithMembership(
        seed: UserAndOrgSeedData<Provider>
    ): UserInfo = context(lens) {
        pgRest(CreateUserAndOrg, RpcPost(seed) {
            contentProfile(IamSchema)
            accept(Select.Accept.SingularRepresentation)
        })
    }

    @JvmInline
    value class IdentityProviderId(val value: String)

    data class UserAndOrgSeedData<E : Enum<E>>(
        val p_provider: E,
        val p_provider_subject: String,
        val p_email: String,
        val p_first_name: String? = null,
        val p_org_slug: String,
        val p_role: Role? = null,
        val p_is_primary_owner: Boolean = true
    ) {
        constructor(
            provider: E,
            provider_subject: IdentityProviderId,
            email: Email,
            org_slug: Slug,
            role: Role,
            is_primary_owner: Boolean = true
        ) : this(
            p_provider = provider,
            p_provider_subject = provider_subject.value,
            p_email = email.value,
            p_org_slug = org_slug.value,
            p_role = role,
            p_is_primary_owner = is_primary_owner
        )
    }
}