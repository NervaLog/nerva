package dev.dailywombat.utils

import io.matthewnelson.encoding.base32.Base32
import io.matthewnelson.encoding.core.Encoder.Companion.encodeToString

object Encoding {

    val crockford = Base32.Crockford.Builder {
        isLenient(enable = true)
        encodeLowercase(enable = true)
        backFillBuffers(enable = true)
    }

    fun ByteArray.crockford32() =
        encodeToString(crockford)
}
