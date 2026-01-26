package dev.dailywombat.postgrest.headers

import java.time.ZoneId

sealed interface Prefer {
    val value: String

    enum class Resolution(override val value: String) : Prefer {
        MergeDuplicates("resolution=merge-duplicates"),
        IgnoreDuplicates("resolution=ignore-duplicates"),
    }

    enum class Handling(override val value: String) : Prefer {
        Strict("handling=strict"),
        Lenient("handling=lenient")
    }

    enum class Return(override val value: String) : Prefer {
        Minimal("return=minimal"),
        HeadersOnly("return=headers-only"),
        Representation("return=representation")
    }

    data object MissingDefault : Prefer {
        override val value = "missing=default"
    }

    data class Timezone(val tz: ZoneId) : Prefer {
        override val value = "timezone=$tz"
    }

    data class MaxAffected(val n: Int) : Prefer {
        override val value = "max-affected=$n"
    }
}