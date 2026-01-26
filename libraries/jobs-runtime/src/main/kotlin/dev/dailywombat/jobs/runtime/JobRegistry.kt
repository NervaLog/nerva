package dev.dailywombat.jobs.runtime

import dev.dailywombat.jobs.Job
import io.github.classgraph.ClassGraph
import io.github.oshai.kotlinlogging.KLogger
import io.github.oshai.kotlinlogging.KotlinLogging

private val logger = KotlinLogging.logger {}

/**
 * Registry of all discovered Job handlers.
 *
 * Jobs are discovered via classpath scanning at startup. Each Job subclass
 * that is a Kotlin object will be registered automatically.
 *
 * **Duplicate Detection**: If two Job objects declare the same `type` string,
 * discovery will fail with [DuplicateJobTypeException]. This catches configuration
 * errors at startup rather than at runtime.
 *
 * Usage:
 * ```
 * // On startup - validates no duplicates
 * JobRegistry.logDiscovered()
 *
 * // Get a handler
 * val job = JobRegistry["run_planner"]
 * ```
 */
object JobRegistry {

    /**
     * Exception thrown when two Job handlers declare the same type string.
     */
    class DuplicateJobTypeException(
        val type: String,
        val handlers: List<String>
    ) : RuntimeException(
        "Duplicate job type '$type' declared by multiple handlers: ${handlers.joinToString()}"
    )

    /**
     * All discovered Job handlers.
     */
    val discovered: List<Job<*>> by lazy {
        ClassGraph()
            .enableClassInfo()
            .scan()
            .use { result ->
                result.getSubclasses(Job::class.java.name)
                    .loadClasses(Job::class.java)
                    .mapNotNull { clazz ->
                        try {
                            // Kotlin objects have a static INSTANCE field
                            clazz.getDeclaredField("INSTANCE").get(null) as? Job<*>
                        } catch (_: NoSuchFieldException) {
                            // Not a Kotlin object, skip
                            logger.debug { "Skipping non-object Job subclass: ${clazz.name}" }
                            null
                        } catch (e: Exception) {
                            logger.warn(e) { "Failed to load Job: ${clazz.name}" }
                            null
                        }
                    }
            }
    }

    private val byType: Map<String, Job<*>> by lazy {
        // Check for duplicates before building the map
        val duplicates = discovered
            .groupBy { it.type }
            .filter { it.value.size > 1 }

        if (duplicates.isNotEmpty()) {
            // Report the first duplicate found (fail fast)
            val (type, handlers) = duplicates.entries.first()
            throw DuplicateJobTypeException(
                type = type,
                handlers = handlers.map { it::class.qualifiedName ?: it::class.java.name }
            )
        }

        discovered.associateBy { it.type }
    }

    /**
     * Get a job handler by type.
     */
    operator fun get(type: String): Job<*>? = byType[type]

    /**
     * All registered job types.
     */
    val types: Set<String> get() = byType.keys

    /**
     * Number of registered handlers.
     */
    val size: Int get() = discovered.size

    /**
     * Log all discovered job handlers.
     */
    fun logDiscovered(log: KLogger = logger) {
        if (discovered.isEmpty()) {
            log.warn { "No job handlers discovered on classpath" }
        } else {
            log.info { "Discovered ${discovered.size} job handler(s): ${types.sorted().joinToString()}" }
        }
    }
}
