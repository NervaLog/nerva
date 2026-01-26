package dev.nerva

import dev.dailywombat.flyway.modules.ModuleSchema

interface DatabaseContainer {
    fun start(modules: List<ModuleSchema>)
    fun stop()
}