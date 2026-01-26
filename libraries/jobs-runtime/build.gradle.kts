@file:Suppress("UnstableApiUsage")

plugins {
    kotlin("jvm")
    `java-library`
    `jvm-test-suite`
}

repositories {
    mavenCentral()
}

dependencies {
    api(project(":libraries:jobs"))

    implementation(project(":libraries:utils"))
    implementation(project(":libraries:postgrest"))

    // For PostgreSQL LISTEN/NOTIFY
    implementation(libs.pgjdbc.ng)

    // For Job classpath discovery
    implementation(libs.classgraph.classgraph)

    // Metrics
    implementation(libs.http4k.ops.micrometer)
    implementation(libs.micrometer.registry.prometheus)

    testImplementation(testFixtures(project(":libraries:utils")))
    testImplementation(testFixtures(project(":libraries:postgrest")))
}

kotlin {
    jvmToolchain(21)
    compilerOptions { freeCompilerArgs.add("-Xcontext-parameters") }
}

tasks.test {
    useJUnitPlatform()
}

// Integration test suite
testing {
    suites {
        val integrationTest by registering(JvmTestSuite::class) {
            useJUnitJupiter()

            dependencies {
                implementation(project())
                implementation(project(":libraries:jobs"))
                implementation(project(":libraries:postgrest"))
                implementation(project(":libraries:utils"))
                implementation(testFixtures(project(":libraries:postgrest")))
                implementation(testFixtures(project(":libraries:utils")))

                // TestContainers
                implementation(libs.testcontainers)
                implementation(libs.testcontainers.postgresql)
                implementation(libs.testcontainers.toxiproxy)

                // JDBC for direct assertions and LISTEN/NOTIFY
                implementation(libs.pgjdbc.ng)

                // Coroutine testing
                implementation(libs.kotlinx.coroutines.test)

                // Assertions
                implementation(libs.kotest.assertions.core)

                // Logging
                implementation(libs.kotlin.logging.jvm)
                implementation(libs.logback.classic)
            }

            targets {
                all {
                    testTask.configure {
                        shouldRunAfter(tasks.test)

                        // Only run chaos tests if explicitly requested
                        if (!project.hasProperty("chaos")) {
                            exclude("**/chaos/**")
                        }
                    }
                }
            }
        }
    }
}

// Convenience task: ./gradlew :libraries:jobs-runtime:integrationTest
