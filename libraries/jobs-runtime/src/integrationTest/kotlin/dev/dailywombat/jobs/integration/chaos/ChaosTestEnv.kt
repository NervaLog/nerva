package dev.dailywombat.jobs.integration.chaos

import dev.dailywombat.PostgresContainer
import dev.dailywombat.TestContainers
import dev.dailywombat.flyway.FlywayConfig
import dev.dailywombat.flyway.migration.FlywayMigrator
import dev.dailywombat.postgrest.PostgRestClient
import dev.dailywombat.postgrest.PostgRestConfig
import eu.rekawek.toxiproxy.Proxy
import eu.rekawek.toxiproxy.ToxiproxyClient
import eu.rekawek.toxiproxy.model.ToxicDirection
import io.github.oshai.kotlinlogging.KotlinLogging
import org.http4k.core.Uri
import org.testcontainers.containers.GenericContainer
import org.testcontainers.containers.Network
import org.testcontainers.containers.ToxiproxyContainer
import org.testcontainers.containers.wait.strategy.Wait
import org.testcontainers.postgresql.PostgreSQLContainer
import org.testcontainers.utility.DockerImageName
import java.time.Duration

private val logger = KotlinLogging.logger {}

/**
 * Chaos test environment with Toxiproxy for network fault injection.
 *
 * Architecture:
 * ```
 * Test Code ──> PostgREST ──> Toxiproxy ──> PostgreSQL
 *                   │
 *                   └──> Direct JDBC (for assertions)
 * ```
 *
 * This setup allows injecting faults in the PostgREST→Postgres connection
 * to test resilience of job processing.
 *
 * Usage:
 * ```kotlin
 * @Tag("chaos")
 * class NetworkPartitionTest {
 *     companion object {
 *         @BeforeAll @JvmStatic
 *         fun beforeAll() = ChaosTestEnv.start()
 *
 *         @AfterAll @JvmStatic
 *         fun afterAll() = ChaosTestEnv.stop()
 *     }
 *
 *     @Test
 *     fun `job processing survives network partition`() {
 *         ChaosTestEnv.cutConnection()
 *         // ... test behavior ...
 *         ChaosTestEnv.restoreConnection()
 *     }
 * }
 * ```
 */
object ChaosTestEnv {

    private const val TOXIPROXY_IMAGE = "ghcr.io/shopify/toxiproxy:2.9.0"
    private const val TOXIPROXY_CONTROL_PORT = 8474
    private const val POSTGRES_PROXY_PORT = 5433

    private const val POSTGRES_DNS = "postgres-chaos"
    private const val TOXIPROXY_DNS = "toxiproxy"
    private const val POSTGREST_DNS = "postgrest-chaos"

    private val network: Network = Network.newNetwork()

    // Containers
    private lateinit var postgresContainer: PostgreSQLContainer
    private lateinit var toxiproxyContainer: ToxiproxyContainer
    private lateinit var postgrestContainer: GenericContainer<*>

    // Toxiproxy client and proxy
    private lateinit var toxiproxyClient: ToxiproxyClient
    private lateinit var postgresProxy: Proxy

    private var started = false

    /**
     * Start the chaos test environment.
     */
    fun start() {
        if (started) return
        logger.info { "Starting ChaosTestEnv..." }

        // 1. Start Postgres
        postgresContainer = PostgreSQLContainer(DockerImageName.parse("postgres:18"))
            .withDatabaseName(PostgresContainer.Db)
            .withUsername(PostgresContainer.Username)
            .withPassword(PostgresContainer.Password)
            .withNetwork(network)
            .withNetworkAliases(POSTGRES_DNS)
            .withInitScript("db/init/add-pgrest-users.sql")
            .waitingFor(Wait.forListeningPort().withStartupTimeout(Duration.ofSeconds(30)))

        postgresContainer.start()
        logger.info { "Postgres started" }

        // 2. Run migrations
        FlywayMigrator.migrate(
            FlywayConfig(
                host = postgresContainer.host,
                port = postgresContainer.getMappedPort(5432),
                database = PostgresContainer.Db,
                username = PostgresContainer.Username,
                password = PostgresContainer.Password
            ),
            modules = TestContainers.databaseModules
        )
        logger.info { "Migrations complete" }

        // 3. Start Toxiproxy
        toxiproxyContainer = ToxiproxyContainer(DockerImageName.parse(TOXIPROXY_IMAGE))
            .withNetwork(network)
            .withNetworkAliases(TOXIPROXY_DNS)

        toxiproxyContainer.start()
        logger.info { "Toxiproxy started" }

        // 4. Create proxy for Postgres
        toxiproxyClient = ToxiproxyClient(
            toxiproxyContainer.host,
            toxiproxyContainer.getMappedPort(TOXIPROXY_CONTROL_PORT)
        )

        postgresProxy = toxiproxyClient.createProxy(
            "postgres-proxy",
            "0.0.0.0:$POSTGRES_PROXY_PORT",
            "$POSTGRES_DNS:5432"
        )
        logger.info { "Postgres proxy created: $POSTGRES_DNS:5432 -> toxiproxy:$POSTGRES_PROXY_PORT" }

        // 5. Start PostgREST pointing at the proxy
        val proxyDbUri =
            "postgres://${PostgresContainer.Username}:${PostgresContainer.Password}@$TOXIPROXY_DNS:$POSTGRES_PROXY_PORT/${PostgresContainer.Db}"

        val schemas = TestContainers.databaseModules.map { it.name }

        postgrestContainer = GenericContainer(DockerImageName.parse("postgrest/postgrest:v12.2"))
            .withNetwork(network)
            .withNetworkAliases(POSTGREST_DNS)
            .withExposedPorts(3000, 3001)
            .withEnv("PGRST_DB_URI", proxyDbUri)
            .withEnv("PGRST_DB_SCHEMAS", schemas.joinToString(","))
            .withEnv("PGRST_DB_ANON_ROLE", "web_anon")
            .withEnv("PGRST_SERVER_HOST", "0.0.0.0")
            .withEnv("PGRST_SERVER_PORT", "3000")
            .withEnv("PGRST_ADMIN_SERVER_PORT", "3001")
            .waitingFor(Wait.forHttp("/ready").forPort(3001).forStatusCode(200))

        postgrestContainer.start()
        logger.info { "PostgREST started (via proxy)" }

        started = true
        logger.info { "ChaosTestEnv started successfully" }
    }

    /**
     * Stop all containers.
     */
    fun stop() {
        if (!started) return
        logger.info { "Stopping ChaosTestEnv..." }

        runCatching { postgrestContainer.stop() }
        runCatching { toxiproxyContainer.stop() }
        runCatching { postgresContainer.stop() }

        started = false
        logger.info { "ChaosTestEnv stopped" }
    }

    /**
     * PostgREST client (routes through Toxiproxy).
     */
    val pgRest: PostgRestClient
        get() {
            val uri = Uri.of("http://${postgrestContainer.host}:${postgrestContainer.getMappedPort(3000)}")
            return dev.dailywombat.postgrest.Postgrest.client(PostgRestConfig(uri))
        }

    /**
     * Direct JDBC URL (bypasses Toxiproxy, for assertions).
     */
    val directJdbcUrl: String
        get() = "jdbc:postgresql://${postgresContainer.host}:${postgresContainer.getMappedPort(5432)}/${PostgresContainer.Db}"

    /**
     * JDBC URL via proxy (for testing LISTEN/NOTIFY resilience).
     */
    val proxyJdbcUrl: String
        get() = "jdbc:pgsql://${toxiproxyContainer.host}:${toxiproxyContainer.getMappedPort(POSTGRES_PROXY_PORT)}/${PostgresContainer.Db}"

    // --- Fault Injection ---

    /**
     * Cut the connection between PostgREST and Postgres.
     * Simulates a network partition.
     */
    fun cutConnection() {
        logger.info { "Cutting connection (timeout toxic)" }
        postgresProxy.toxics()
            .timeout("cut", ToxicDirection.DOWNSTREAM, 1)
    }

    /**
     * Restore the connection after cutting.
     */
    fun restoreConnection() {
        logger.info { "Restoring connection" }
        runCatching {
            postgresProxy.toxics().get("cut").remove()
        }
        runCatching {
            postgresProxy.toxics().get("latency").remove()
        }
        runCatching {
            postgresProxy.toxics().get("bandwidth").remove()
        }
    }

    /**
     * Add latency to the connection.
     */
    fun addLatency(latencyMs: Long, jitterMs: Long = 0) {
        logger.info { "Adding latency: ${latencyMs}ms (jitter: ${jitterMs}ms)" }
        postgresProxy.toxics()
            .latency("latency", ToxicDirection.DOWNSTREAM, latencyMs).jitter = jitterMs
    }

    /**
     * Limit bandwidth (simulates slow network).
     *
     * @param bytesPerSecond Bandwidth limit (0 = no data flows)
     */
    fun limitBandwidth(bytesPerSecond: Long) {
        logger.info { "Limiting bandwidth to $bytesPerSecond bytes/sec" }
        postgresProxy.toxics()
            .bandwidth("bandwidth", ToxicDirection.DOWNSTREAM, bytesPerSecond)
    }

    /**
     * Reset all toxics to restore normal operation.
     */
    fun resetToxics() {
        logger.info { "Resetting all toxics" }
        postgresProxy.toxics().all.forEach { toxic ->
            runCatching { toxic.remove() }
        }
    }
}
