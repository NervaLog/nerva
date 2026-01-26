package dev.dailywombat.flyway.modules

sealed interface DatabaseModuleError {
    data class ClassPathError(val message: String) : DatabaseModuleError
}