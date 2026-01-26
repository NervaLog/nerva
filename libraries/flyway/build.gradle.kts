plugins {
    kotlin("jvm") version "2.2.0"
    `java-test-fixtures`
}

repositories {
    mavenCentral()
}

dependencies {
    implementation(project(":libraries:utils"))

    api(libs.flyway.core)

    api(libs.flyway.postgresql)
    api(libs.postgresql)

    api(libs.jooq)
    api(libs.jooq.kotlin)

    implementation(libs.classgraph.classgraph)

    testImplementation(testFixtures(project(":libraries:utils")))
}

java { toolchain { languageVersion.set(JavaLanguageVersion.of(21)) } }
kotlin {
    jvmToolchain(21)
    compilerOptions { freeCompilerArgs.add("-Xcontext-parameters") }
}


tasks.withType<Test>().configureEach { useJUnitPlatform() }
