@file:Suppress("PropertyName")

package dev.template.iam.model

import arrow.core.raise.context.Raise
import com.github.f4b6a3.uuid.UuidCreator
import dev.template.iam.IamSchema
import dev.template.iam.IamSchema.Orgs
import dev.template.iam.OrgSlug
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestCompanion
import dev.dailywombat.postgrest.PostgRestEntity
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.Insert
import dev.dailywombat.postgrest.actions.Select
import dev.dailywombat.postgrest.actions.Select.Accept.SingularRepresentation
import dev.dailywombat.postgrest.headers.Prefer.Return
import org.http4k.format.Jackson
import java.time.Instant
import java.util.*

data class Org(
    override val id: UUID = UuidCreator.getTimeOrderedEpoch(),
    override val created_at: Instant = Instant.now(),
    val updated_at: Instant = Instant.now(),
    val name: String,
    val slug: OrgSlug,
    val status: OrgStatus = OrgStatus.active,
    val plan_key: OrgPlanKey = OrgPlanKey.solo,
    val seats_limit: Int = 1,
) : PostgRestEntity<Org> {

    context(
        pgRest: PostgRestClient,
        _: Raise<PostgRestError>
    )
    fun save() = context(lens) {
        pgRest(Orgs, Insert(this) {
            contentProfile(IamSchema)
            returning(Return.Representation)
            accept(SingularRepresentation)
        })
    }

    companion object : PostgRestCompanion<Org> {
        override val lens = Jackson.autoBody<Org>().toLens()
        override val listLens = Jackson.autoBody<List<Org>>().toLens()

        val WombatBurrowsSlug = OrgSlug("0P51K0TZJ402ZCZ3W6K45X5JQW")

        @Suppress("RedundantWith")
        context(
            pgRest: PostgRestClient,
            _: Raise<PostgRestError>
        )
        fun by(slug: OrgSlug) = with(lens) {
            pgRest(Orgs, Select<Org> {
                eq(Org::slug, slug)
                acceptProfile(IamSchema)
                accept(SingularRepresentation)
            })
        }
    }
}