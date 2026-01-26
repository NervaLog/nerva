package dev.dailywombat.jobs.integration.support

import dev.dailywombat.PostgresContainer
import dev.dailywombat.TestContainers
import dev.dailywombat.jobs.integration.support.db.JobsDb
import dev.dailywombat.postgrest.PostgRestClient
import io.github.oshai.kotlinlogging.KotlinLogging

private val logger = KotlinLogging.logger {}

/**
 * Integration test environment for jobs library.
 *
 * Wraps the existing TestContainers infrastructure and adds jobs-specific helpers.
 *
 * Usage:
 * ```kotlin
 * class MyIntegrationTest {
 *     companion object {
 *         @BeforeAll @JvmStatic
 *         fun beforeAll() = JobsIntegrationEnv.start()
 *
 *         @AfterAll @JvmStatic
 *         fun afterAll() = JobsIntegrationEnv.stop()
 *     }
 *
 *     @BeforeEach
 *     fun beforeEach() = JobsIntegrationEnv.resetJobs()
 *
 *     @Test
 *     fun `my test`() {
 *         context(JobsIntegrationEnv.pgRest) {
 *             // ...
 *         }
 *     }
 * }
 * ```
 */
object JobsIntegrationEnv {

    /**
     * Start all required containers (Postgres + PostgREST).
     * Idempotent - safe to call multiple times.
     */
    fun start() {
        logger.info { "Starting JobsIntegrationEnv..." }
        TestContainers.start()
        logger.info { "JobsIntegrationEnv started" }
    }

    /**
     * Stop all containers.
     */
    fun stop() {
        logger.info { "Stopping JobsIntegrationEnv..." }
        TestContainers.stop()
        logger.info { "JobsIntegrationEnv stopped" }
    }

    /**
     * PostgREST client for job operations.
     */
    val pgRest: PostgRestClient
        get() = TestContainers.postgRestClient()

    /**
     * JDBC URL for direct database access (LISTEN/NOTIFY, assertions).
     * Uses pgjdbc-ng driver for async notifications.
     */
    val jdbcUrl: String
        get() = PostgresContainer.jdbcNgUrl

    /**
     * Standard JDBC URL (for drivers that don't support pgjdbc-ng).
     */
    val standardJdbcUrl: String
        get() = "jdbc:postgresql://localhost:${PostgresContainer.Container.getMappedPort(PostgresContainer.Port)}/${PostgresContainer.Db}"

    /**
     * Database credentials.
     */
    val dbUsername: String = PostgresContainer.Username
    val dbPassword: String = PostgresContainer.Password

    /**
     * Reset job tables to clean state.
     * Call in @BeforeEach to isolate tests.
     */
    fun resetJobs() {
        JobsDb.withConnection { conn ->
            JobsDb.truncateJobs(conn)
        }
        logger.debug { "Jobs tables reset" }
    }

    /**
     * Dump current state of jobs table for debugging.
     */
    fun dumpState(): String = buildString {
        appendLine("=== Jobs State ===")
        JobsDb.withConnection { conn ->
            val counts = JobsDb.countByStatus(conn)
            appendLine("Status counts: $counts")

            val jobs = JobsDb.fetchAllJobs(conn)
            if (jobs.isEmpty()) {
                appendLine("No jobs in table")
            } else {
                jobs.forEach { job ->
                    appendLine(
                        "  ${job.id}: ${job.jobType} [${job.status}] attempts=${job.attempts} error=${
                            job.lastError?.take(
                                50
                            )
                        }"
                    )
                }
            }
        }
    }
}
