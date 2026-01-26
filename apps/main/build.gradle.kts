import org.gradle.api.tasks.testing.Test
import org.gradle.internal.os.OperatingSystem

plugins {
    kotlin("jvm") version "2.2.0"
    application
    `jvm-test-suite`
    id("com.google.cloud.tools.jib") version "3.5.1"
    id("de.undercouch.download") version "5.6.0"
}

repositories {
    mavenCentral()
}

dependencies {
    // DailyWombat libraries (from GitHub Packages)
    implementation(project(":libraries:utils"))
    implementation(project(":libraries:postgrest"))
    implementation(project(":libraries:flyway"))
    implementation(project(":libraries:jobs-runtime"))

    implementation(project(":modules:iam"))
    implementation(project(":modules:cache"))
    implementation(project(":modules:nerva"))

    implementation(project(":integrations:iam-stytch"))

    implementation(libs.dailywombat.stytch)
    implementation(libs.dailywombat.stripe)
    implementation(libs.dailywombat.runtime)

    // JWT for session management
    implementation("com.auth0:java-jwt:4.4.0")

    testImplementation(testFixtures(project(":libraries:utils")))
}

java { toolchain { languageVersion.set(JavaLanguageVersion.of(21)) } }
kotlin {
    jvmToolchain(21)
    compilerOptions { freeCompilerArgs.add("-Xcontext-parameters") }
}
application { mainClass.set("dev.template.app.App") }


jib {
    container { jvmFlags = listOf("-XX:+UseContainerSupport") }
    from { image = "eclipse-temurin:21-jre" }
    to {
        val dockerTag = System.getenv("GITHUB_RELEASE_TAG") ?: "latest"
        // GitHub account for GHCR
        image = "ghcr.io/topwombat/nerva-${project.name}:$dockerTag"
        logger.lifecycle("Docker image: $image")
        auth {
            username = "_"  // GitHub ignores username
            password = System.getenv("GITHUB_TOKEN")
        }
    }
}

tasks.withType<Test>().configureEach { useJUnitPlatform() }

testing {
    suites {
        val integrationTest by registering(JvmTestSuite::class) {
            dependencies {
                implementation(project())
                implementation(project(":modules:cache"))
                implementation(testFixtures(project(":libraries:utils")))
                implementation(testFixtures(project(":libraries:postgrest")))
            }

            targets {
                all {
                    testTask.configure {
                        shouldRunAfter(tasks.test)
                    }
                }
            }
        }
    }
}

// Integration tests run separately from unit tests
// Run with: ./gradlew :apps:main:integrationTest
tasks.named("check") {
    // Don't run integration tests on normal check - they require GEMINI_API_KEY
    // dependsOn(testing.suites.named("integrationTest"))
}

// ==================== Tailwind CSS v4 ====================

val tailwindVersion = "4.1.8"
val tailwindDir = layout.buildDirectory.dir("tailwind")
val tailwindBinaryName = when {
    OperatingSystem.current().isMacOsX -> "tailwindcss-macos-arm64"
    OperatingSystem.current().isLinux -> "tailwindcss-linux-x64"
    else -> "tailwindcss-windows-x64.exe"
}
val tailwindBinary = tailwindDir.map { it.file(tailwindBinaryName) }

// Download Tailwind CLI binary
val downloadTailwind by tasks.registering(de.undercouch.gradle.tasks.download.Download::class) {
    src("https://github.com/tailwindlabs/tailwindcss/releases/download/v$tailwindVersion/$tailwindBinaryName")
    dest(tailwindBinary)
    overwrite(false)
}

// Make binary executable
val setupTailwind by tasks.registering {
    dependsOn(downloadTailwind)
    doLast { tailwindBinary.get().asFile.setExecutable(true) }
}

// Build CSS (runs during assemble)
val buildCss by tasks.registering(Exec::class) {
    dependsOn(setupTailwind)
    commandLine(
        tailwindBinary.get().asFile.absolutePath,
        "-i", "src/main/resources/assets/css/input.css",
        "-o", "src/main/resources/assets/css/output.css",
        "--minify"
    )
}

// Watch CSS (for development)
// Note: --watch=always prevents exit when stdin closes (e.g., in Gradle/scripts)
val watchCss by tasks.registering(Exec::class) {
    dependsOn(setupTailwind)
    commandLine(
        tailwindBinary.get().asFile.absolutePath,
        "-i", "src/main/resources/assets/css/input.css",
        "-o", "src/main/resources/assets/css/output.css",
        "--watch=always"
    )
}

// Integrate into build lifecycle
tasks.processResources { dependsOn(buildCss) }
