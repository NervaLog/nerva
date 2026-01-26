package dev.dailywombat.utils

import java.text.Normalizer

@JvmInline
value class Email(val value: String)

@JvmInline
value class Slug(val value: String) {

    companion object {
        fun of(input: String): Slug =
            Slug(
                input.lowercase()
                    .normalize()
                    .replace(Regex("[^a-z0-9]+"), "-")
                    .trim('-')
            )

        private fun String.normalize(): String =
            Normalizer
                .normalize(this, Normalizer.Form.NFD)
                .replace(Regex("\\p{InCombiningDiacriticalMarks}+"), "")
    }
}
