plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.jib)
    application
}

application {
    mainClass.set("dev.template.example_app.App")
}

dependencies {
    implementation(project(":libraries:utils"))
    implementation(project(":libraries:postgrest"))
    implementation(project(":libraries:flyway"))

    implementation(libs.http4k.core)
    implementation(libs.http4k.server.undertow)
    implementation(libs.http4k.config)
    implementation(libs.http4k.platform.k8s)

    implementation(libs.arrow.core)
    implementation(libs.kotlin.logging.jvm)
    implementation(libs.logback.classic)
    implementation(libs.logstash.logback.encoder)
}

jib {
    from { image = "eclipse-temurin:21-jre" }
    to {
        // Update with your registry
        image = "your-registry/example-app"
        tags = setOf("latest", project.version.toString())
    }
    container {
        mainClass = "dev.template.example_app.App"
        ports = listOf("8080", "8081")
    }
}
