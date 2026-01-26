@file:Suppress("PropertyName")

package dev.template.iam

import arrow.core.raise.context.Raise
import dev.template.iam.IamSchema
import dev.template.iam.IamSchema.Users
import dev.template.iam.model.*
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestCompanion
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.Select
import dev.dailywombat.utils.Email
import dev.dailywombat.utils.Slug
import org.http4k.format.Jackson
import java.util.*

data class UserInfo(
    val id: UUID,
    val email: String,
    val first_name: String? = null,
    val status: UserStatus,
    val org_membership: List<OrgMembershipInfo>,
) {
    data class OrgMembershipInfo(
        val role: OrgRole? = null,      // From PostgREST embed query
        val org_role: OrgRole? = null,  // From stored proc JSON
        val is_primary_owner: Boolean,
        val orgs: OrgInfo
    ) {
        // Get role from either source
        val effectiveRole: OrgRole get() = role ?: org_role ?: OrgRole.member
    }

    data class OrgInfo(
        val id: UUID,
        val name: String? = null,
        val slug: Slug
    )

    companion object : PostgRestCompanion<UserInfo> {
        override val lens = Jackson.autoBody<UserInfo>().toLens()
        override val listLens = Jackson.autoBody<List<UserInfo>>().toLens()

        context(
            pgRest: PostgRestClient,
            _: Raise<PostgRestError>
        )
        fun byEmail(email: Email) =
            context(listLens) {
                pgRest(Users, Select<UserInfo> {
                    eq(UserInfo::email, email.value)
                    select {
                        props(
                            User::id,
                            User::email,
                            User::first_name,
                            User::status
                        )
                        embed("org_membership") {
                            props(
                                OrgMembership::role,
                                OrgMembership::is_primary_owner
                            )
                            embed("orgs") {
                                props(
                                    Org::id,
                                    Org::name,
                                    Org::slug,
                                    Org::plan_key
                                )
                            }
                        }
                    }
                    acceptProfile(IamSchema)
                }).firstOrNull()
            }
    }
}