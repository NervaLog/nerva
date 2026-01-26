@file:Suppress("PropertyName", "RedundantWith")

package dev.template.iam.model

import arrow.core.raise.context.Raise
import com.github.f4b6a3.uuid.UuidCreator
import dev.template.iam.IamSchema
import dev.template.iam.IamSchema.Users
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


data class User(
    override val id: UUID = UuidCreator.getTimeOrderedEpoch(),
    override val created_at: Instant = Instant.now(),

    val updated_at: Instant = Instant.now(),

    val email: String?,
    val email_verified: Boolean = false,

    val first_name: String? = null,
    val last_name: String? = null,
    val avatar_url: String? = null,

    val status: UserStatus = UserStatus.active,
) : PostgRestEntity<User> {

    context(
        pgRest: PostgRestClient,
        _: Raise<PostgRestError>
    )
    fun save() =
        context(lens) {
            pgRest(Users, Insert(this) {
                contentProfile(IamSchema)
                returning(Return.Representation)
                accept(SingularRepresentation)
            })
        }

    companion object : PostgRestCompanion<User> {
        override val lens = Jackson.autoBody<User>().toLens()
        override val listLens = Jackson.autoBody<List<User>>().toLens()

        context(
            pgRest: PostgRestClient,
            _: Raise<PostgRestError>
        )
        fun findByEmail(email: String) =
            context(listLens) {
                pgRest(Users, Select<User> {
                    eq(User::email, email)
                    acceptProfile(IamSchema)
                }).firstOrNull()
            }
    }
}