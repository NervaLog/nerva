package dev.dailywombat.flyway.migration

import org.flywaydb.core.api.FlywayException

sealed interface MigrationError {
    data class FlywayError(val flywayException: FlywayException) : MigrationError
    data class UnknownError(val t: Throwable) : MigrationError
}