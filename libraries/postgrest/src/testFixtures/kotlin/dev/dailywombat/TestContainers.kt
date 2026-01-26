@file:Suppress("ConstPropertyName", "MayBeConstant", "TestFunctionName", "HasPlatformType")

package dev.nerva

import arrow.core.getOrElse
import dev.dailywombat.flyway.modules.DatabaseModules
import dev.dailywombat.postgrest.Postgrest
import org.testcontainers.containers.Network

/**
 * Singleton object to manage the lifecycle of all Testcontainers required for integration tests.
 * If test requires PG/PgREST, import these at the top:
 *
 * ```kotlin
 * import org.junit.jupiter.api.AfterAll
 * import org.junit.jupiter.api.BeforeAll
 * ```
 * then insert the following stanza in the body of the test class:
 *
 * ```kotlin
 *     companion object {
 *         @BeforeAll
 *         @JvmStatic
 *         fun before() = TestContainers.start()
 *
 *         @AfterAll
 *         @JvmStatic
 *         fun after() = TestContainers.stop()
 *     }
 * ```
 *
 * The tests can then access PgREST on @see [PostgrestContainer.Uri]
 */
object TestContainers {

    internal val DockerNetwork: Network = Network.newNetwork()

    val databaseModules by lazy {
        DatabaseModules
            .discoverModules()
            .getOrElse { throw RuntimeException(it.message) }
    }

    fun start() {
        PostgresContainer.start(databaseModules)
        PostgrestContainer.start(databaseModules)
    }

    fun stop() {
        PostgrestContainer.stop()
        PostgresContainer.stop()
    }

    fun postgRestClient() =
        Postgrest.client(PostgrestContainer.config)
}

