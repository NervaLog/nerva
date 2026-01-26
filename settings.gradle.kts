rootProject.name = "nerva"

// Most libraries moved to DailyWombat organization on GitHub Packages
// See: https://github.com/DailyWombat

// Core libraries
include(
    ":libraries:utils",
    ":libraries:flyway",
    ":libraries:postgrest",
    ":libraries:jobs",
    ":libraries:jobs-runtime",
    ":libraries:resilience",
)

include(
    ":modules:iam",
    ":modules:cache",
    ":modules:nerva",
)

include(
    ":integrations:iam-stytch",
)

include(
    ":apps:main",
)


buildCache {
    local { isEnabled = true }

//    // to turn on when there's a team to make use of a shared cache
//    remote<HttpBuildCache> {
//        // Replace "..." with your actual remote cache server URL
//        url = uri("https://your-remote-cache-server.com/cache")
//        push = true
//    }
}

plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}
