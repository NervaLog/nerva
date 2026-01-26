plugins {
    kotlin("jvm")
    `java-library`
}

repositories {
    mavenCentral()
}

dependencies {
    api(project(":libraries:flyway"))

    implementation(project(":libraries:utils"))
    implementation(project(":libraries:postgrest"))

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
