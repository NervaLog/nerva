package dev.dailywombat.utils

import com.github.f4b6a3.uuid.UuidCreator
import dev.dailywombat.utils.Encoding.crockford32
import java.util.*
import kotlin.random.Random

object Seeds {

    fun freshUuid7(): UUID =
        UuidCreator.getTimeOrderedEpoch()

    fun freshBase32Id(bytes: Int): String =
        Random.nextBytes(bytes).crockford32()
}