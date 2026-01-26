package dev.template.example.enums

/**
 * Example enum - must be synchronized with PostgreSQL enum.
 *
 * See: V001__example__create-enums.sql
 */
enum class ThingStatus {
    draft,
    active,
    archived,
}
