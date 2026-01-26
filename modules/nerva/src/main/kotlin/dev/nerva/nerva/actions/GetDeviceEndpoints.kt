package dev.nerva.nerva.actions

import arrow.core.raise.Raise
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestError
import dev.dailywombat.postgrest.actions.Select
import dev.nerva.nerva.NervaSchema
import dev.nerva.nerva.models.DeviceEndpoint
import org.http4k.format.Jackson
import java.util.*

object GetDeviceEndpoints {

    private val listLens = Jackson.autoBody<List<DeviceEndpoint>>().toLens()

    context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
    operator fun invoke(orgId: UUID): List<DeviceEndpoint> = context(listLens) {
        pgRest(NervaSchema.DeviceEndpoints, Select<DeviceEndpoint> {
            acceptProfile(NervaSchema)
            eq(DeviceEndpoint::org_id, orgId)
            eq(DeviceEndpoint::push_enabled, true)
        })
    }
}
