@file:Suppress("FunctionName")

package dev.dailywombat.postgrest

import org.http4k.core.Request
import org.http4k.core.Uri

interface PostgRestAction<I : Any> {
    fun toRequest(baseUri: Uri, entity: String): Request
}