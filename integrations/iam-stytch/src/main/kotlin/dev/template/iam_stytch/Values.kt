package dev.template.iam_stytch

import dev.dailywombat.utils.Seeds

@JvmInline
value class DiscoveryRequestToken(val value: String = Seeds.freshBase32Id(32))