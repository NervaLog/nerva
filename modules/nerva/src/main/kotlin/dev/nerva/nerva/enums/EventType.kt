package dev.nerva.nerva.enums

import com.fasterxml.jackson.annotation.JsonValue

enum class EventType(@JsonValue val value: String) {
    CALENDAR_EVENT("calendar_event"),
    EMAIL_RECEIVED("email_received"),
    SLACK_MESSAGE("slack_message"),
    GITHUB_NOTIFICATION("github_notification"),
    TASK_DUE("task_due"),
    MEETING_REMINDER("meeting_reminder"),
    GENERIC("generic");

    companion object {
        fun fromValue(value: String): EventType =
            entries.find { it.value == value }
                ?: throw IllegalArgumentException("Unknown EventType: $value")
    }
}
