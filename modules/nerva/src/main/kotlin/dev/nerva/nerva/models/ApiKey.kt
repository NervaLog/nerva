@file:Suppress("PropertyName")

package dev.nerva.nerva.models

import java.time.Instant
import java.util.*

data class ApiKey(
    val id: UUID,
    val org_id: UUID,
    val key_prefix: String,
    val name: String,
    val description: String?,
    val scopes: List<String>,
    val created_at: Instant,
    val last_used_at: Instant?,
    val expires_at: Instant?,
    val revoked_at: Instant?
)
