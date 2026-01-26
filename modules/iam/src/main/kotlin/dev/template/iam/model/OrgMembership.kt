@file:Suppress("PropertyName", "EnumEntryName")

package dev.template.iam.model

import dev.dailywombat.postgrest.PostgRestCompanion
import dev.dailywombat.postgrest.PostgRestEntity
import dev.dailywombat.utils.Seeds.freshUuid7
import org.http4k.format.Jackson
import java.time.Instant
import java.util.*

data class OrgMembership(
    override val id: UUID = freshUuid7(),
    override val created_at: Instant = Instant.now(),

    val org_id: UUID,
    val user_id: UUID,
    val role: OrgRole,

    val is_primary_owner: Boolean = true,
    val joined_at: Instant = Instant.now(),
) : PostgRestEntity<OrgMembership> {

    companion object : PostgRestCompanion<OrgMembership> {
        override val lens = Jackson.autoBody<OrgMembership>().toLens()
        override val listLens = Jackson.autoBody<List<OrgMembership>>().toLens()

        enum class Role {
            owner, admin, member, viewer
        }
    }
}