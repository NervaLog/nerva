plugins {
    alias(libs.plugins.kotlin.jvm)
    `java-library`
}

dependencies {
    // Integration connects a module to an external service
    api(project(":modules:_example"))
    api(project(":external:_example"))

    implementation(libs.arrow.core)
    implementation(libs.kotlin.logging.jvm)
}
