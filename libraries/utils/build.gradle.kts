plugins {
    kotlin("jvm")
    `java-library`
    `java-test-fixtures`
}

repositories {
    mavenCentral()
}

dependencies {
    api(platform(libs.arrow.stack))
    api(libs.arrow.core)
    api(libs.arrow.core.high.arity)
    api(libs.arrow.fx.coroutines)

    api(platform(libs.http4k.bom))
    api(libs.http4k.core)
    api(libs.http4k.config)
    api(libs.http4k.server.undertow)
    api(libs.http4k.format.jackson)
    api(libs.http4k.client.okhttp)
    api(libs.http4k.template.pebble)
    api(libs.http4k.platform.k8s)
    api(libs.http4k.ops.opentelemetry)

    api(libs.uuid.creator)
    implementation(libs.bouncycastle.bcprov)

    implementation(platform(libs.encoding.bom))
    implementation(libs.encoding.base32)

    api(libs.slf4j.api)
    api(libs.logback.classic)
    api(libs.logstash.logback.encoder)
    api(libs.janino)     //  for conditionals in the logback config
    api(libs.kotlin.logging.jvm)

    testFixturesApi(libs.junit.jupiter)
    testFixturesApi(libs.kotest.runner.junit5)
    testFixturesApi(libs.kotest.assertions.core)
}

java { toolchain { languageVersion.set(JavaLanguageVersion.of(21)) } }
kotlin {
    jvmToolchain(21)
    compilerOptions { freeCompilerArgs.add("-Xcontext-parameters") }
}

tasks.test {
    useJUnitPlatform()
}