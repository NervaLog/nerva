package dev.dailywombat.flyway.migration

import arrow.core.Either
import arrow.core.Either.Companion.catch
import arrow.core.raise.context.bind
import arrow.core.raise.context.either
import dev.dailywombat.flyway.FlywayConfig
import dev.dailywombat.flyway.modules.ModuleSchema
import org.flywaydb.core.Flyway
import org.flywaydb.core.api.FlywayException
import org.flywaydb.core.api.callback.Callback
import org.flywaydb.core.api.output.MigrateResult

//  TODO: refactor to RaiseDSL
object FlywayMigrator {

    /**
     * @param callbacks if anything needs to get at some point in the upgrade cycle.
     * This is where, e.g., you put the call to issue the PostgREST NOTIFY for schema cache reload.
     * @see [org.flywaydb.core.api.callback.Event] for when these can be triggered.
     */
    fun migrate(
        config: FlywayConfig,
        modules: List<ModuleSchema>,
        vararg callbacks: Callback,
    ): Either<MigrationError, MigrateResult> = either {
        val schemas = modules.map { it.name } + FlywayConfig.ExtensionsSchema
        val locations = modules.map { it.migrationPath() }
        val placeholders = schemas.associateWith { it }

        runFlyway(
            Flyway
                .configure()
                .placeholders(placeholders)
                .schemas(*schemas.toTypedArray())
                .defaultSchema("flyway")
                .locations(*locations.toTypedArray())
                .outOfOrder(true)
                .validateMigrationNaming(true)
                .dataSource(config.dataSource)
                .callbacks(*callbacks)
                .load()
        ).bind()
    }

    private fun runFlyway(flyway: Flyway) =
        catch { flyway.migrate() }.mapLeft {
            when (it) {
                is FlywayException -> MigrationError.FlywayError(it)
                else -> MigrationError.UnknownError(it)
            }
        }
}