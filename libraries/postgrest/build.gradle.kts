plugins {
    kotlin("jvm")
    `java-library`
    `java-test-fixtures`
}

repositories {
    mavenCentral()
}

dependencies {
    implementation(project(":libraries:utils"))
    implementation(project(":libraries:flyway"))

    testFixturesApi(project(":libraries:utils"))
    testFixturesApi(project(":libraries:flyway"))

    testFixturesApi(platform(libs.testcontainers.bom))
    testFixturesApi(libs.testcontainers)
    testFixturesApi("org.testcontainers:postgresql:1.21.4")
}

kotlin {
    jvmToolchain(21)
    compilerOptions { freeCompilerArgs.add("-Xcontext-parameters") }
}