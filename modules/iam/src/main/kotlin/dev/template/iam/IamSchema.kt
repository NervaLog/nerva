@file:Suppress("HasPlatformType")

package dev.template.iam

import dev.dailywombat.flyway.modules.ModuleSchema
import dev.dailywombat.flyway.modules.Entity.Companion.enum
import dev.dailywombat.flyway.modules.Entity.Companion.storedFunc
import dev.dailywombat.flyway.modules.Entity.Companion.table
import dev.dailywombat.flyway.modules.Entity.Companion.view

object IamSchema : ModuleSchema() {
    override val name = "iam"

    val UserStatus = enum("user_status")
    val Users = table("users")

    val authProvider = enum("auth_provider")
    val Identities = table("identities")

    val OrgStatus = enum("org_status")
    val Orgs = table("orgs")

    val OrgRole = enum("org_role")
    val OrgMembership = table("org_membership")
    val OrgSeatUsage = view("org_seat_usage")

    val CreateUserAndOrg = storedFunc("create_user_and_org")
    val EnforceOrgOwnerInvariants = storedFunc("enforce_org_owner_invariants")

    val TouchUpdatedAt = storedFunc("touch_updated_at")
}