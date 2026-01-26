package dev.nerva.nerva.models

import java.time.Instant
import java.util.*

data class DeviceEndpoint(
    val id: UUID,
    val org_id: UUID,
    val user_id: UUID,
    val device_token: String,
    val platform: String,
    val device_name: String?,
    val push_enabled: Boolean,
    val created_at: Instant,
    val updated_at: Instant,
    val last_push_at: Instant?
)
