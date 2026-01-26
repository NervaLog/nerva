package dev.template.example.actions

import arrow.core.raise.context.Raise
import dev.template.example.ExampleSchema
import dev.template.example.model.Thing
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.RpcPost
import dev.dailywombat.postgrest.actions.Select
import dev.dailywombat.postgrest.headers.Prefer
import org.http4k.format.Jackson.auto
import org.http4k.lens.BiDiBodyLens

/**
 * Example action - calls a stored procedure to create an entity.
 *
 * Actions are single atomic operations (database calls, API calls).
 * They use context receivers for dependency injection.
 */
object CreateThing {

    private val lens: BiDiBodyLens<Thing> = org.http4k.core.Body.auto<Thing>().toLens()

    private data class Args(
        val p_name: String,
    )

    context(
        pgRest: PostgRestClient,
        _: Raise<PostgRestError>
    )
    operator fun invoke(name: String): Thing = context(lens) {
        pgRest(ExampleSchema.CreateThing, RpcPost(Args(p_name = name)) {
            contentProfile(ExampleSchema)
            accept(Select.Accept.SingularRepresentation)
            returning(Prefer.Return.Representation)
        })
    }
}
