package dev.dailywombat.utils

import arrow.core.Either
import arrow.core.Either.Companion.catch
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.AEADParameters
import org.bouncycastle.crypto.params.KeyParameter
import java.security.SecureRandom


object ChaCha20 {

    sealed class Credential(open val bytes: ByteArray) {
        fun toHex() = bytes.toHexString()

        companion object {
            private val sourceOfRandomness = SecureRandom()
        }

        data class Key(override val bytes: ByteArray) : Credential(bytes) {
            override fun equals(other: Any?) = other is Key && bytes.contentEquals(bytes)
            override fun hashCode() = 31 * bytes.contentHashCode()

            companion object {
                fun generate(): Key = Key(ByteArray(32).apply { sourceOfRandomness.nextBytes(this) })
                fun fromHex(hex: String): Key = Key(hex.hexToByteArray())
            }
        }

        @ConsistentCopyVisibility
        data class Nonce private constructor(override val bytes: ByteArray) : Credential(bytes) {
            override fun equals(other: Any?) = other is Nonce && bytes.contentEquals(bytes)
            override fun hashCode() = 31 * bytes.contentHashCode()

            companion object {
                fun generate(): Nonce = Nonce(ByteArray(12).apply { sourceOfRandomness.nextBytes(this) })
                fun fromHex(hex: String): Nonce = Nonce(hex.hexToByteArray())
            }
        }
    }

    data class Cipher(val key: Credential.Key, val nonce: Credential.Nonce) {
        fun encrypt(bytes: ByteArray) = buildCipher(true).runCipher(bytes)
        fun decrypt(bytes: ByteArray) = buildCipher(false).runCipher(bytes)

        internal fun buildCipher(encryptIfTrueDecryptIfFalse: Boolean) = ChaCha20Poly1305().apply {
            init(
                encryptIfTrueDecryptIfFalse,
                AEADParameters(
                    /* key = */ KeyParameter(key.bytes),
                    /* macSize = */ 128,
                    /* nonce = */ nonce.bytes,
                    /* associatedText = */ null
                )
            )
        }

        internal fun ChaCha20Poly1305.runCipher(data: ByteArray): Either<Throwable, ByteArray> =
            catch {
                ByteArray(getOutputSize(data.size)).apply {
                    val bytesProcessed = processBytes(
                        /* in = */ data,
                        /* inOff = */ 0,
                        /* len = */ data.size,
                        /* out = */ this,
                        /* outOff = */ 0
                    )
                    doFinal(this, bytesProcessed)
                }
            }
    }
}
