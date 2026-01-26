package dev.dailywombat.utils.http4k

import org.http4k.core.HttpMessage
import org.http4k.lens.LensExtractor
import org.http4k.lens.LensFailure
import org.http4k.lens.LensInjector

object Lenses {

    /**
     * [org.http4k.core.Request] or [org.http4k.core.Response]
     * incoming with an empty body.
     */
    val unitEx = LensExtractor<HttpMessage, Unit> {}

    /**
     * [org.http4k.core.Request] or [org.http4k.core.Response]
     * you want to go out with an empty body.
     */
    val unitInj = object : LensInjector<Unit, HttpMessage> {
        override fun <R : HttpMessage> invoke(value: Unit, target: R): R = target
    }

    /**
     * A chaining utility for lenses.
     */
    infix fun <IN, OUT> ((IN) -> OUT).or(fallback: (IN) -> OUT): (IN) -> OUT = { target ->
        try {
            this(target)
        } catch (e: LensFailure) {
            try {
                fallback(target)
            } catch (e2: LensFailure) {
                throw LensFailure(e.failures + e2.failures)
            }
        }
    }
}