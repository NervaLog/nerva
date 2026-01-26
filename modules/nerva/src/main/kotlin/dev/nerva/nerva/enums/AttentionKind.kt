package dev.nerva.nerva.enums

import com.fasterxml.jackson.annotation.JsonValue

enum class AttentionKind(@JsonValue val value: String) {
    IMMEDIATE("immediate"),
    SOON("soon"),
    BATCH("batch"),
    INFO("info");

    companion object {
        fun fromValue(value: String): AttentionKind =
            entries.find { it.value == value }
                ?: throw IllegalArgumentException("Unknown AttentionKind: $value")
    }
}
