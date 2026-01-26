package dev.dailywombat.flyway.modules

sealed class Entity(
    open val name: String,
    open val description: String
) {
    data class Table(override val name: String, override val description: String) : Entity(name, description)
    data class StoredFunc(override val name: String, override val description: String) : Entity(name, description)
    data class Channel(override val name: String, override val description: String) : Entity(name, description)
    data class ErrorCode(override val name: String, override val description: String) : Entity(name, description)
    data class Enum(override val name: String, override val description: String) : Entity(name, description)
    data class View(override val name: String, override val description: String) : Entity(name, description)

    companion object {
        fun table(name: String, description: String = "") = Table(name, description)
        fun storedFunc(name: String, description: String = "") = StoredFunc(name, description)
        fun channel(name: String, description: String = "") = Channel(name, description)
        fun errorCode(name: String, description: String = "") = ErrorCode(name, description)
        fun enum(name: String, description: String = "") = Enum(name, description)
        fun view(name: String, description: String = "") = View(name, description)
    }
}