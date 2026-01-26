package dev.nerva.nerva.enums

import com.fasterxml.jackson.annotation.JsonValue

enum class AttentionStatus(@JsonValue val value: String) {
    PENDING("pending"),
    DELIVERED("delivered"),
    DISMISSED("dismissed"),
    ACTIONED("actioned"),
    EXPIRED("expired");

    companion object {
        fun fromValue(value: String): AttentionStatus =
            entries.find { it.value == value }
                ?: throw IllegalArgumentException("Unknown AttentionStatus: $value")
    }
}
