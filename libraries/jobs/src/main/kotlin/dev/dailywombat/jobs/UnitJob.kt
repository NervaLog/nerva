package dev.dailywombat.jobs

import arrow.core.Either
import arrow.core.right
import com.fasterxml.jackson.databind.ObjectMapper

/**
 * Base class for jobs that take no parameters.
 *
 * Usage:
 * ```
 * object PingJob : UnitJob("ping") {
 *     override suspend operator fun invoke(): JobResult {
 *         return JobResult.Success
 *     }
 * }
 *
 * // Can be called directly:
 * PingJob()
 * ```
 */
abstract class UnitJob(type: String) : Job<Unit>(type, Unit::class) {
    final override suspend operator fun invoke(params: Unit): JobResult = invoke()

    abstract suspend operator fun invoke(): JobResult

    override fun deserialize(
        json: Map<String, Any>?,
        mapper: ObjectMapper
    ): Either<String, Unit> = Unit.right()

    override fun parseAndInvoke(
        json: Map<String, Any>?,
        mapper: ObjectMapper
    ): suspend () -> JobResult = { invoke() }
}