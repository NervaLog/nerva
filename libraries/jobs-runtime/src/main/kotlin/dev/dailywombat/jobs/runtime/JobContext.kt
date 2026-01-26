package dev.dailywombat.jobs.runtime

import dev.dailywombat.postgrest.PostgRestClient
import kotlinx.coroutines.withContext
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.coroutineContext

/**
 * Coroutine context element that holds the PostgRestClient for job execution.
 *
 * Jobs that need database access can retrieve the client via:
 * ```
 * val pgRest = JobContext.current()
 *     ?: return JobResult.Fail("No PostgRestClient in context")
 * ```
 *
 * The JobProcessor sets this context when invoking jobs.
 */
class JobContext(
    val pgRest: PostgRestClient
) : AbstractCoroutineContextElement(Key) {

    companion object Key : CoroutineContext.Key<JobContext> {

        /**
         * Get the current PostgRestClient from the coroutine context.
         *
         * @return The PostgRestClient, or null if not in a job context
         */
        suspend fun current(): PostgRestClient? =
            coroutineContext[Key]?.pgRest

        /**
         * Get the current PostgRestClient, throwing if not available.
         *
         * @throws IllegalStateException if not in a job context
         */
        suspend fun require(): PostgRestClient =
            current() ?: throw IllegalStateException(
                "No PostgRestClient in coroutine context. " +
                        "Jobs must be executed via JobProcessor which provides the context."
            )
    }
}

/**
 * Execute a block with the given PostgRestClient in the coroutine context.
 *
 * Jobs can then access it via [JobContext.current] or [JobContext.require].
 */
suspend fun <T> withJobContext(pgRest: PostgRestClient, block: suspend () -> T): T =
    withContext(JobContext(pgRest)) {
        block()
    }
