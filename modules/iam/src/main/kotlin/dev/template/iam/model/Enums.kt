@file:Suppress("EnumEntryName")

package dev.template.iam.model

enum class OrgRole {
    owner, admin, member, viewer
}

enum class OrgStatus {
    active, suspended, deleted
}

enum class OrgPlanKey {
    solo
}

enum class UserStatus {
    active, disabled, deleted
}