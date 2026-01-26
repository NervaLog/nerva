package dev.dailywombat.utils.http4k

import org.http4k.core.Uri

/**
 * The HTTP origin of the service (e.g. http://localhost)
 */
@JvmInline
value class Origin(val value: Uri)