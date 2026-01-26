@file:Suppress("HasPlatformType")

package dev.nerva.nerva

import dev.dailywombat.flyway.modules.ModuleSchema
import dev.dailywombat.flyway.modules.Entity.Companion.enum
import dev.dailywombat.flyway.modules.Entity.Companion.storedFunc
import dev.dailywombat.flyway.modules.Entity.Companion.table

object NervaSchema : ModuleSchema() {
    override val name = "nerva"

    // Enums
    val EventType = enum("event_type")
    val AttentionKind = enum("attention_kind")
    val AttentionStatus = enum("attention_status")

    // Tables
    val Events = table("events")
    val AttentionProjection = table("attention_projection")
    val DeviceEndpoints = table("device_endpoints")
    val ApiKeys = table("api_keys")

    // Stored procedures
    val IngestEvent = storedFunc("ingest_event")
    val RenderAttentionPayload = storedFunc("render_attention_payload")
    val ValidateApiKey = storedFunc("validate_api_key")
}
