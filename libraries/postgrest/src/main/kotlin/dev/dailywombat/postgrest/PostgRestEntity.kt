@file:Suppress("PropertyName")

package dev.dailywombat.postgrest

import java.time.Instant
import java.util.*

interface PostgRestEntity<A> {
    val id: UUID
    val created_at: Instant
}