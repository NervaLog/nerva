plugins {
    alias(libs.plugins.kotlin.jvm)
    `java-library`
}

dependencies {
    api(project(":libraries:utils"))

    implementation(libs.arrow.core)
    implementation(libs.kotlin.logging.jvm)

    // Add your SDK dependency here:
    // implementation("com.example:sdk:1.0.0")
}
