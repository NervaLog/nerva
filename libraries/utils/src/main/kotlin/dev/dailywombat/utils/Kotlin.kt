package dev.dailywombat.utils

import arrow.core.Either.Companion.catch
import java.security.MessageDigest
import java.util.*
import java.util.concurrent.ConcurrentHashMap

fun <A> List<A>.repeats(): Set<A> {
    val seen = mutableSetOf<A>()
    return filter { !seen.add(it) }.toSet()
}

fun String.sha256() =
    catch {
        MessageDigest
            .getInstance("SHA-256")
            .digest(this@sha256.toByteArray(Charsets.UTF_8))
    }

fun ByteArray.base64Url(): String =
    Base64.getUrlEncoder().withoutPadding().encodeToString(this)

/**
 * NOTE:
 * - not co-routine safe
 * - not race-safe
 */
fun <A : Any, B : Any> memoizedProvider(build: (A) -> B): (A) -> B {
    val cache = ConcurrentHashMap<A, B>()
    return { a -> cache.computeIfAbsent(a, build) }
}