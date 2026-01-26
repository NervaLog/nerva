plugins {
    alias(libs.plugins.kotlin.jvm)
    `java-library`
}

dependencies {
    api(project(":libraries:postgrest"))
    api(project(":libraries:flyway"))

    implementation(libs.arrow.core)
    implementation(libs.kotlin.logging.jvm)
}
