package dev.nerva.nerva.models

import dev.nerva.nerva.enums.AttentionKind
import dev.nerva.nerva.enums.AttentionStatus
import java.time.Instant
import java.util.*

data class AttentionItem(
    val id: UUID,
    val org_id: UUID,
    val attention_id: String,
    val attention_kind: AttentionKind,
    val status: AttentionStatus,
    val title: String,
    val body: String?,
    val deeplink_url: String?,
    val event_count: Int,
    val first_event_at: Instant,
    val last_event_at: Instant,
    val event_ids: List<UUID>,
    val created_at: Instant,
    val updated_at: Instant,
    val delivered_at: Instant?,
    val actioned_at: Instant?,
    val expires_at: Instant?
)
