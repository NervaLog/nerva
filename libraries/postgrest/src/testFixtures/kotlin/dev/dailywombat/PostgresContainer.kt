@file:Suppress("ConstPropertyName", "TestFunctionName")

package dev.nerva

import arrow.core.getOrElse
import dev.dailywombat.flyway.FlywayConfig
import dev.dailywombat.flyway.migration.FlywayMigrator
import dev.dailywombat.flyway.migration.MigrationError
import dev.dailywombat.flyway.modules.ModuleSchema
import org.http4k.core.Uri
import org.testcontainers.containers.wait.strategy.Wait
import org.testcontainers.containers.PostgreSQLContainer
import org.testcontainers.utility.DockerImageName
import org.testcontainers.utility.MountableFile
import java.time.Duration

object PostgresContainer : DatabaseContainer {
    const val DockerTag = "postgres:18"
    const val DnsName = "postgres-db"

    const val Username = "testuser"
    const val Password = "testpassword"
    const val Port = 5432
    const val Db = "testdb"

    val jdbcNgUrl
        get() = Uri.of("")
            .scheme("pgsql")
            .host("localhost")
            .port(Container.getMappedPort(Port))
            .path("/$Db")
            .let { "jdbc:$it" }

    val Container: PostgreSQLContainer<*> by lazy {
        PostgreSQLContainer(DockerImageName.parse(DockerTag))
            .withDatabaseName(Db)
            .withUsername(Username)
            .withPassword(Password)
            .withExposedPorts(Port)
            .withNetwork(TestContainers.DockerNetwork)
            // Use withCopyFileToContainer instead of withInitScript to avoid testcontainers shading bugs
            .withCopyFileToContainer(
                MountableFile.forClasspathResource("db/init/add-pgrest-users.sql"),
                "/docker-entrypoint-initdb.d/add-pgrest-users.sql"
            )
            .waitingFor(
                Wait.forListeningPort()
                    .withStartupTimeout(Duration.ofSeconds(15))
            ).apply { withNetworkAliases(DnsName) }
    }

    override fun start(modules: List<ModuleSchema>) {
        if (!Container.isRunning) Container.start()

        FlywayMigrator.migrate(
            FlywayConfig(
                host = "localhost",
                port = Container.getMappedPort(Port),
                database = Db,
                username = Username,
                password = Password
            ),
            modules = modules
        ).getOrElse {
            when (it) {
                is MigrationError.FlywayError -> throw it.flywayException
                is MigrationError.UnknownError -> throw it.t
            }
        }
    }

    override fun stop() {
        if (Container.isRunning) Container.stop()
    }
}