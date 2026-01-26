@file:Suppress("EnumEntryName")

package dev.dailywombat.utils.http4k

/**
 * Status values for webhook response DTOs.
 */
enum class WebhookStatus {
    processed,
    recorded,
    duplicate,
    ignored
}
