plugins {
    kotlin("jvm")
    `java-library`
}

dependencies {
    api(platform(libs.arrow.stack))
    api(libs.arrow.resilience)
    api(libs.arrow.core)

    implementation(libs.kotlin.logging.jvm)
    implementation(libs.slf4j.api)

    // Coroutines for Schedule
    implementation(libs.kotlinx.coroutines.test)

    testImplementation(testFixtures(project(":libraries:utils")))
}

kotlin {
    jvmToolchain(21)
    compilerOptions { freeCompilerArgs.add("-Xcontext-parameters") }
}

tasks.test {
    useJUnitPlatform()
}
