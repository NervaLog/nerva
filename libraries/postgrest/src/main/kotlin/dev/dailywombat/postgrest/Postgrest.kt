package dev.dailywombat.postgrest

import dev.dailywombat.utils.memoizedProvider
import org.flywaydb.core.api.callback.BaseCallback
import org.flywaydb.core.api.callback.Context
import org.flywaydb.core.api.callback.Event
import org.http4k.client.OkHttp
import org.http4k.core.HttpHandler

object Postgrest {
    const val SchemaReloadStanza = "NOTIFY pgrst, 'reload schema';"

    private val ClientProvider =
        memoizedProvider<Pair<PostgRestConfig, HttpHandler>, PostgRestClient> { p ->
            PostgRestClient(p.first, p.second)
        }

    fun client(
        config: PostgRestConfig,
        handler: HttpHandler = OkHttp()
    ) = ClientProvider(config to handler)

    /**
     * Issues the clarion call to reload the PostgREST schema cache
     * after all the migrations are done.
     *
     * @see https://docs.postgrest.org/en/latest/references/schema_cache.html#schema-cache-reloading-with-notify
     */
    val SchemaReloadFlywayCallback = object : BaseCallback() {
        override fun supports(event: Event, context: Context?): Boolean =
            event == Event.AFTER_MIGRATE

        override fun handle(event: Event, context: Context) {
            context.connection.createStatement().use { statement ->
                statement.execute(SchemaReloadStanza)
            }
        }
    }
}