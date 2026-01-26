plugins {
    kotlin("jvm") version "2.2.0"
}

repositories {
    mavenCentral()
}

// Add DailyWombat GitHub Packages repository to all subprojects
subprojects {
    repositories {
        mavenCentral()
        maven {
            name = "GitHubPackages"
            url = uri("https://maven.pkg.github.com/DailyWombat/*")
            credentials {
                username = project.findProperty("gpr.user") as String? ?: System.getenv("GITHUB_ACTOR")
                // Prefer DAILYWOMBAT_TOKEN for cross-org package access, fallback to GITHUB_TOKEN for local dev
                password = project.findProperty("gpr.key") as String?
                    ?: System.getenv("DAILYWOMBAT_TOKEN")
                    ?: System.getenv("GITHUB_TOKEN")
            }
        }
    }
}

java { toolchain { languageVersion.set(JavaLanguageVersion.of(21)) } }
kotlin {
    jvmToolchain(21)
    compilerOptions { freeCompilerArgs.add("-Xcontext-parameters") }
}
