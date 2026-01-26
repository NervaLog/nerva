@file:Suppress("PropertyName")

package dev.nerva.nerva.models

import com.fasterxml.jackson.databind.JsonNode
import dev.nerva.nerva.enums.EventType
import java.time.Instant
import java.util.*

data class Event(
    val id: UUID,
    val org_id: UUID,
    val provider: String,
    val external_id: String,
    val event_type: EventType,
    val payload: JsonNode,
    val occurred_at: Instant,
    val ingested_at: Instant
)
