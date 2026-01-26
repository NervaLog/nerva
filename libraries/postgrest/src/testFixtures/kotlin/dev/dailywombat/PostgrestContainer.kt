@file:Suppress("ConstPropertyName")

package dev.nerva

import dev.dailywombat.flyway.modules.ModuleSchema
import dev.dailywombat.postgrest.PostgRestConfig
import org.http4k.core.Uri
import org.testcontainers.containers.GenericContainer
import org.testcontainers.containers.wait.strategy.Wait
import org.testcontainers.utility.DockerImageName

// TODO: clean up this config
object PostgrestContainer : DatabaseContainer {

    val config: PostgRestConfig
        get() = PostgRestConfig(Uri.of("http://localhost:${Container.getMappedPort(Port)}"))

    const val DockerTag = "postgrest/postgrest:v14.1"

    const val Port = 43000
    const val AdminPort = 43001

    private var Schemas = listOf<String>()

    val Container: PostgrestContainer by lazy {
        PostgrestContainer(DockerImageName.parse(DockerTag))
            .withExposedPorts(Port, AdminPort)
            .withNetwork(TestContainers.DockerNetwork)
            .waitingFor(
                Wait.forHttp("/ready")
                    .forPort(AdminPort)
                    .forStatusCode(200)
            ).apply {
                withEnv(
                    "PGRST_DB_URI",
                    "postgres://${PostgresContainer.Username}:${PostgresContainer.Password}@${PostgresContainer.DnsName}:${PostgresContainer.Port}/${PostgresContainer.Db}"
                )
                withEnv("PGRST_DB_SCHEMAS", Schemas.joinToString(","))
                withEnv("PGRST_DB_ANON_ROLE", "web_anon")
                withEnv("PGRST_JWT_ROLE_CLAIM_KEY", ".role")
                withEnv("PGRST_SERVER_HOST", "0.0.0.0")
                withEnv("PGRST_SERVER_PORT", "$Port")
                withEnv("PGRST_ADMIN_SERVER_PORT", "$AdminPort")
                withEnv(
                    "PGRST_JWT_SECRET",
                    "ewogICJrZXlzIjogWwogICAgewogICAgICAiYWxnIjogIlJTMjU2IiwKICAgICAgImQiOiAiQVJTeTZ4VGVfaThpa00xRTVrdlA0eGVKdlJ0SV9XVGZTWWtVNlFNN2hTU2NHeTBVbUJYLTYta2J6UmpVVzZodlQtaXMxbmktZW5xYnd6NG9lYkVUeXpINGZtVWdVMHFxUko4Mnh3VDBzTFVFendlZlhNcFlVYkhWUGlDcV9lc3NUMjN0QnVCcTBFS2c2MTFQZzJjdkQ5eDJoOWlkNkxsNms3SngxNWY5SXRWekxqdHNWeEg3aTdNSTg1R1dxMG9KZ0dwOU9UMG1maWxZZVlDX1c5NkJtY0JLRjk3b3JXbTVKeC1tZDlNcjl4WDB3NFBzYXY5YW1JRGs5aU5mT3hkb29YZlVOMUhhRHhFRTBBcE1hYXhYSUFsVlNOVkFQNlF0ODRsblQzZmRhMl9sZTR0eTItck5laFhkV2EtUlVsUkxWa1Bwc0J2bEM2YzBJZTk2a1hWNS1RIiwKICAgICAgImRwIjogImxnN3JfemN1Z3l6Ym9vaDhqcUNXVTZMcFlsTHlEanQtLUVCTHpzQjhkbGdaLVRjNU56YmtjTkcyR3NIcWN2YnVYWFJzaEQwaU5mUERfOFpyWkVJWmN1TVJ4eU5NSkJfUHRlNC1iMHlxWWdMWVRldEh6SUJINkhYMnZiOV8wUG1sZFVyLWptU05wU2pfWDNYSmQ4SkdpdEpLZ0h2VFZvNzBQR2ttSWhMc3JwRSIsCiAgICAgICJkcSI6ICJHcEttRkVRMWprUnl4MTBsYTZNdDRMQzNwNy1DejBqdWNRQjk0NnVVODdRSE9jaWQzUDRCYXlRTXc1U0szekVRZWxuWEVFdlZmVXkzQk9TRkdpekgwbjNwLXVlcXpSc0d3dl9lZlZsYWhJczhrS2ZjeFNlY0RPQjgxbFNwdnhDamVXa2F0ajNuLWswLUN2cnlwOVFjM3l0Z1hCZUN1V0dFeU5PaEJTQk42SDAiLAogICAgICAiZSI6ICJBUUFCIiwKICAgICAgImtleV9vcHMiOiBbCiAgICAgICAgInNpZ24iLAogICAgICAgICJ2ZXJpZnkiCiAgICAgIF0sCiAgICAgICJrdHkiOiAiUlNBIiwKICAgICAgIm4iOiAiaDlwYnlSSlRQeHlPMTE5NFIyQmNhejEtSUtsRXMzYXlfcl9IYTh3T0dGM2x5cWhmS28zUDY3aXE5V0swTGd5ck1LUUY5clkxRFd2dGJ3c0hfSUhhdlAxWl9IVmVSRkp1TXpjNXd6djEyZmg2eERETWNrQ2R5TmN0aEtRSzdQbGNqcWt6RmpCZlFPY0NBRnZBWEZFOUJtLVBqbFM4WDNCTE5HdnphdE5reEREQzFCejVaaU1MRzlqT2ZUSUU1NGk5YUtGdFNmY2NtZXNIU003eFhGWUpTYmw5OHhZM3FYV2VHcVNFY3ktT0MyVTd2bnVzbkVJdUVWdERmdWMzV2luZWdDUzFQVlFlTm5MdjBWS1NYUERDdmxzQW1VY285UTBrX2g0TXFQbDVIa0hUVWdzUlZCUzJBRmUycmtDLWt4VlRpeXVrTVVhejVxUjBLcV9XMXF5OEZRIiwKICAgICAgInAiOiAidmZvMjJDcU81R1JkVTBVa0lFNzkxY1hqTkZwWDJzeUxlaE9wdFl0bnJaTHlkMWk5dkJkY0syNC04azB4VkQ3ZklwOElKSzdIdFMxUm13Yy02SEFiOUxVWjd6RHlBSGw1N2trZEU0ZVVZZ19sVnF0NUZ4MW9McGdpVzlZREVZWUtWeU9UY211d2tSSEx3b0Z2RE5Pdy1xSXNnSDJfdmdWVndqX2k3X2p6b2xrIiwKICAgICAgInEiOiAidHhEV0xjRjBnakY5WHdUa1ZJUG5CZ1JlYWlxa0xQektUOG0zOEJ2SjFqVVh0QUFaSDdsWURpUUE5WFdWbHF1Z1plUlItU0tUQkJHcGNmUW93dUlNYWNCWHBJeHBTM3E4UkZEaEhORWxLU085ZVdlcnZsazJ4cXNKSlFyWTFuekZsQnF5MUhMT2FOS09yNG1IclV3ejNUei1XQm9FZmJ1TFJYZWNfVkZUR0IwIiwKICAgICAgInFpIjogIktnMVdId1UyS0VUWXVKakNpV3RfeW1UYzh2cFgxdzUyb2dGVjRfOHRCZUdfaDJPSU9NdkRwaEkxWXQyVEVfMUFteE1PVVJXNmxYazBRQlBZUHFpT0ljeEM5UzZLVDFmMVk4WlRzTERjLVBsWDN6R1M5UDBkek5ORExvRk1pTFVfTFlMYURLVXBuN3VTN0tnc0ZGQVdHTTZrTnBpRm15RXJKc3dkeEVnWlhITSIKICAgIH0KICBdCn0="
                )
            }
    }

    override fun start(modules: List<ModuleSchema>) {
        Schemas = modules.map { it.name }
        if (!Container.isRunning) Container.start()
    }

    override fun stop() {
        if (Container.isRunning) Container.stop()
    }

    class PostgrestContainer(imageName: DockerImageName) :
        GenericContainer<PostgrestContainer>(imageName)
}