package dev.dailywombat.flyway.modules

import arrow.core.Either.Companion.catch
import dev.dailywombat.flyway.modules.DatabaseModuleError.ClassPathError
import io.github.classgraph.ClassGraph

object DatabaseModules {

    fun discoverModules() = catch {
        ClassGraph()
            .enableClassInfo()
            .scan()
            .use { r ->
                r.getSubclasses(ModuleSchema::class.java.name)
                    .loadClasses(ModuleSchema::class.java)
                    .map { it.getDeclaredField("INSTANCE").get(null) as ModuleSchema }
            }
    }.mapLeft { ClassPathError(it.message ?: "Unknown error") }
}