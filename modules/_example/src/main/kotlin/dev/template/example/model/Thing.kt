package dev.template.example.model

import dev.template.example.enums.ThingStatus
import java.util.UUID

/**
 * Example entity - copy this pattern for domain models.
 */
data class Thing(
    val id: UUID,
    val name: String,
    val status: ThingStatus,
)
