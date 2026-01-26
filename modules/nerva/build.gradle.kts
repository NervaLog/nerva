plugins {
    kotlin("jvm")
    `java-library`
}

dependencies {
    implementation(project(":libraries:utils"))
    implementation(project(":libraries:flyway"))
    implementation(project(":libraries:postgrest"))
    implementation(project(":libraries:jobs"))
    implementation(project(":libraries:jobs-runtime"))

    testImplementation(testFixtures(project(":libraries:utils")))
    testImplementation(testFixtures(project(":libraries:postgrest")))
    testImplementation(project(":modules:iam"))
    testImplementation(libs.dailywombat.runtime)
}

kotlin {
    jvmToolchain(21)
    compilerOptions { freeCompilerArgs.add("-Xcontext-parameters") }
}

tasks.test {
    useJUnitPlatform()
}
