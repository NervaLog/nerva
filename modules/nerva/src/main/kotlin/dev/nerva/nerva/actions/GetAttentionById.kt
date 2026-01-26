package dev.nerva.nerva.actions

import arrow.core.raise.Raise
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.Select
import dev.nerva.nerva.NervaSchema
import dev.nerva.nerva.models.AttentionItem
import org.http4k.format.Jackson
import java.util.*

object GetAttentionById {

    private val listLens = Jackson.autoBody<List<AttentionItem>>().toLens()

    context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
    operator fun invoke(id: UUID): AttentionItem? = context(listLens) {
        pgRest(NervaSchema.AttentionProjection, Select<AttentionItem> {
            acceptProfile(NervaSchema)
            eq(AttentionItem::id, id)
        }).firstOrNull()
    }
}
