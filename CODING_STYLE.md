# Coding Style (Canonical)

> These rules are **not suggestions**.
> If a rule exists, it reflects a learned failure mode in this codebase.

---

## 0. Meta-Rules (Read First)

* **Prefer invariants over cleverness**
* **Determinism beats convenience**
* **The database is the source of truth**
* **Types > comments**
* **If it can be encoded in the type system, do so**
* **If behavior matters, test it**

---

## 1. JSON Serialization

### Rules

* **All JSON serialization uses http4k's Jackson integration** — No other JSON libraries (kotlinx.serialization, Gson, etc.)
* **Never create JSON from strings**
* **Never use annotations to alias camelCased fields into snake_cased. Always name class members snake_cased directly**
* **Never manually escape JSON**
* **Never build JSON with `String`, `StringBuilder`, or templates**
* **Always serialize via data classes + http4k lenses**

### Rationale

* Prevents invalid JSON
* Guarantees schema consistency
* Enables compiler-checked refactors
* Makes tests trivial

### Examples

```kotlin
// ❌ BAD — string concatenation
val json = """{"name": "$name", "value": $value}"""

// ❌ BAD — manual builder
val json = buildString {
    append("{\"name\": \"")
    append(name)
    append("\"}")
}

// ✅ GOOD — typed payload + lens
data class MyPayload(
    val name: String,
    val value: Int
)

val lens = Jackson.autoBody<MyPayload>().toLens()
val payload = MyPayload(name = "foo", value = 42)
```

---

## 2. Multi-Dollar String Interpolation

### Rules

* **Never use `${'$'}` to escape dollar signs**
* **Use multi-dollar prefix (`$$`, `$$$`, etc.) for strings containing literal `$`**
* **Match the prefix to the content** — use `$$` when you need single `$` literals, `$$$` when you need `$$` literals

### Rationale

Kotlin 2.1+ supports multi-dollar string interpolation. The prefix `$$` means two consecutive dollar signs trigger interpolation, leaving single `$` as literals. This eliminates the ugly `${'$'}` escape pattern.

### Examples

```kotlin
// ❌ BAD — old escape pattern
val sql = """
    DO ${'$'}${'$'}
    BEGIN
        SELECT * FROM users WHERE name = ${'$'}1;
    END
    ${'$'}${'$'};
""".trimIndent()

// ✅ GOOD — multi-dollar prefix
val sql = $$"""
    DO $$
    BEGIN
        SELECT * FROM users WHERE name = $1;
    END
    $$;
""".trimIndent()

// ✅ GOOD — interpolation still works with $$variable
val tableName = "users"
val sql = $$"""
    DO $$
    BEGIN
        SELECT * FROM $$tableName WHERE id = $1;
    END
    $$;
""".trimIndent()
```

### Common Use Cases

* **PostgreSQL anonymous blocks** — `DO $$ ... $$`
* **Shell scripts** — `$HOME`, `$PATH`
* **JSON Schema** — `$ref`, `$id`
* **GraphQL variables** — `$userId`

---

## 3. `when` Statements

### Rules

* **Do not use braces around branches unless required**
* **Prefer `when(value)` over `when {}`**
* **If you need guards + value matching, nest**
* **Never stack `==` checks inside `when {}`**
* **Prefer `when` over `if/else`** — Unless it would make code unnecessarily convoluted, always use `when`. If `if/else` spans more than one line, always use `when` instead.

### Rationale

* Maintains exhaustiveness
* Improves readability
* Reduces accidental fall-through logic

### Examples

```kotlin
// ❌ BAD — boolean soup
when {
    status.successful -> logger.debug { "Updated ${videoId.value}" }
    status == Status.UNAUTHORIZED -> { }
    status == Status.FORBIDDEN -> { }
    status == Status.NOT_FOUND -> { }
    status == Status.TOO_MANY_REQUESTS -> { }
    else -> { }
}
```

```kotlin
// ✅ GOOD — structured and exhaustive
when {
    status.successful ->
        logger.debug { "Updated ${videoId.value}" }

    else -> when (status) {
        Status.UNAUTHORIZED -> { }
        Status.FORBIDDEN -> { }
        Status.NOT_FOUND -> { }
        Status.TOO_MANY_REQUESTS -> { }
        else -> { }
    }
}
```

---

## 4. Small-Cardinality Value Sets

### Rules

* **Never use `String` for finite sets**
* **Always use `enum class`**
* **Do not alias enum names to uppercase strings**
* **Enum values are lower-case**
* **Suppress naming warnings explicitly**

### Required Pattern

```kotlin
@file:Suppress("EnumEntryName")

enum class MyEnum {
    value0,
    value1
}
```

### Rationale

* Eliminates invalid states
* Improves refactor safety
* Enables exhaustive `when`

---

## 5. IDs, Identity, and Value Types

### Rules

* **All IDs are `UUID`**
* **Never use `String` or `TEXT` for identifiers**
* **Wrap IDs in `@JvmInline value class` at boundaries**
* **No naked UUIDs crossing modules**

### Example

```kotlin
@JvmInline
value class VideoId(val value: UUID)
```

### Database Rule

* **Postgres columns for IDs are `UUID`, never `TEXT`**
* **Casting UUID ↔ TEXT is a bug**

---

## 6. Typed Strings Over Raw Strings

### Rules

* **Never use raw `String` for structured data**
* **Use pre-existing typed representations** — `Uri`, `Email`, `UUID`, `Instant`, etc.
* **Wrap in a value class when no type exists** — If the string has semantic meaning, create a `@JvmInline value class`
* **Raw strings are only for unstructured text** — Names, descriptions, freeform content

### Rationale

* Prevents mixing semantically different strings (e.g., passing a URL where an email is expected)
* Enables compiler-checked refactors
* Makes intent explicit at call sites
* Eliminates invalid state construction

### Examples

```kotlin
// ❌ BAD — raw strings for structured data
data class VideoSummary(
    val video_id: String,
    val url: String,           // What kind of URL? Is it validated?
    val author_email: String   // Could be swapped with url by accident
)

// ✅ GOOD — typed representations
data class VideoSummary(
    val video_id: VideoId,
    val url: Uri,
    val author_email: Email
)

// ✅ GOOD — value class for domain-specific strings
@JvmInline
value class VideoId(val value: String)

@JvmInline
value class ChannelName(val value: String)
```

### When Raw Strings Are Acceptable

* Human-readable names: `val title: String`
* Freeform descriptions: `val description: String`
* Unstructured content: `val notes: String`

---

## 7. Actions & Business Flows

### Canonical Shape

All business logic follows this template:

```kotlin
object DoStuff {
    context(DependenciesAsNeeded)
    operator fun invoke(arguments) {
        // pure decision logic
    }
}
```

### Rules

* **No mutable state**
* **No hidden side effects**
* **Dependencies are explicit via `context()`**
* **Name objects with verbs**

### 80-Line Limit (Hard Rule)

**No class or object may exceed 80 lines.** This is not a guideline—it is a hard limit.

When a class approaches 80 lines, extract focused utilities:

* **`internal` visibility** — module-scoped, not exposed to dependents
* **Action object pattern** — `object Name { operator fun invoke(...) }`
* **Single responsibility** — one purpose per utility
* **Independently testable** — no hidden dependencies

### What to Extract

Common extraction candidates:

* **Error mapping** → `mapping/Map*To*.kt`
* **Hash computation** → `observe/Compute*Hash.kt`
* **Request/response building** → `actions/Build*.kt`
* **Entitlement key generation** → `*EntitlementKeys.kt`
* **Retry/backoff logic** → `mapping/*RetryPolicy.kt`
* **Validation logic** → `actions/Validate*.kt`

### Package Organization

Organize extracted utilities by purpose:

```
module/
├── adapters/           # Main entry points (e.g., SurfacePort implementations)
├── actions/            # Business operations (verbs: Build*, Create*, Update*)
├── mapping/            # Error/type conversions (Map*To*)
├── observe/            # Observation/query utilities
└── model/              # Data types and value objects
```

### Rationale

* Small units are easier to test
* Single responsibility is enforceable
* Code review is tractable
* Merge conflicts are localized
* Cognitive load stays bounded

---

## 8. Errors & Control Flow

### Rules

* **No exceptions for business logic**
* **Use typed results or `Raise<E>`**
* **Errors are data**
* **Retryability must be encoded in the type**
* **Never return from the middle of a function or expression**
* **Use `?.let {}` for nullable transformations**

### Preferred Patterns

* `sealed interface Error`
* `Either<Error, Result>`
* `context(Raise<DomainError>)`

### Never Pattern Match on Either

Always use `fold` to handle `Either`. Never use `when` or `is` checks.

```kotlin
// ❌ BAD — pattern matching
when (result) {
    is Either.Right -> result.value
    is Either.Left -> handleError(result.value)
}

// ✅ GOOD — fold
result.fold(
    ifLeft = { handleError(it) },
    ifRight = { it }
)
```

### Use `it` for Single Lambda Parameters

When a lambda has exactly one parameter, use `it` instead of naming the parameter.

```kotlin
// ❌ BAD — unnecessary named parameter
result.fold(
    ifLeft = { error -> handleError(error) },
    ifRight = { value -> value }
)

// ✅ GOOD — use it
result.fold(
    ifLeft = { handleError(it) },
    ifRight = { it }
)

// ✅ GOOD — named parameter when it improves clarity in complex lambdas
emails.map { email ->
    val normalized = email.lowercase()
    val domain = normalized.substringAfter("@")
    EmailInfo(normalized, domain)
}

// ✅ GOOD — type annotation required for type inference (e.g., Arrow recover)
recover(
    block = { doSomething() },
    recover = { error: DomainError -> handleError(error) }
)
```

**Exception:** When type inference requires an explicit type annotation (common with Arrow's `recover`, generic lambdas, etc.), use a named parameter with its type.

### Extract Multi-Lambda Arguments

For functions that take more than one lambda, or take a lambda in a non-final argument position, when those lambdas exceed 2 lines, extract implementations and use member references where possible.

```kotlin
// ❌ BAD — inline lambdas obscure the call structure
recover(
    block = {
        val user = fetchUser(id)
        val profile = fetchProfile(user)
        validateProfile(profile)
        saveToDatabase(profile)
    },
    recover = { error: DomainError ->
        logger.error { "Failed: $error" }
        mapToResponse(error)
    }
)

// ✅ GOOD — extracted and referenced
private fun fetchAndSaveProfile(id: UserId): Profile {
    val user = fetchUser(id)
    val profile = fetchProfile(user)
    validateProfile(profile)
    return saveToDatabase(profile)
}

private fun handleError(error: DomainError): Response {
    logger.error { "Failed: $error" }
    return mapToResponse(error)
}

recover(
    block = { fetchAndSaveProfile(id) },
    recover = ::handleError
)
```

### Early Returns Are Forbidden

Functions return at the end, not in the middle. Early returns hide control flow and make reasoning harder.

```kotlin
// ❌ BAD — early return
fun getClaims(request: Request): Claims? {
    val cookie = request.cookies().find { it.name == COOKIE_NAME }
        ?: return null
    return decode(cookie.value)
}

// ✅ GOOD — single return point
fun getClaims(request: Request): Claims? =
    request.cookies().find { it.name == COOKIE_NAME }?.let { decode(it.value) }
```

### Use `?.let {}` for Nullable Transformations

When transforming a nullable value, use `?.let {}` instead of verbose `when` patterns.

```kotlin
// ❌ BAD — verbose when pattern
fun parseId(node: JsonNode): UserId? =
    when (val id = node["id"]?.asText()) {
        null -> null
        else -> UserId(id)
    }

// ✅ GOOD — idiomatic Kotlin
fun parseId(node: JsonNode): UserId? =
    node["id"]?.asText()?.let { UserId(it) }
```

Chain `?.let {}` for multi-step transformations:

```kotlin
// ✅ GOOD — chained transformations
fun parseUser(body: String): User? =
    Jackson.parse(body)
        .get("user")
        ?.get("id")
        ?.asText()
        ?.let { User(UserId(it)) }
```

---

## 9. Database & SQL Invariants

### Rules

* **Postgres is the source of truth**
* **All reads must be deterministic**
* **Every `jsonb_agg()` has an explicit `ORDER BY`**
* **No implicit ordering**
* **Stored procedures are read-only unless explicitly named otherwise**
* **Flyway migration versions are `V` + current epoch millis** — e.g., `V1769193718000__cache__create-tables.sql`

### Forbidden

* Relying on insertion order
* Mutating state in "read" paths
* Logic split between Kotlin and SQL

---

## 10. Logging

### Rules

* **Logs are structured**
* **No string concatenation in logs**
* **Logs describe facts, not guesses**
* **No logging inside tight loops unless justified**

```kotlin
logger.info {
    mapOf(
        "videoId" to videoId.value,
        "status" to status
    )
}
```

---

## 11. Tests

### Rules

* **Behavior without tests does not exist**
* **Integration tests > mocks**
* **TestContainers preferred**
* **Tests assert structure, not formatting**

### Required Coverage

* Determinism
* Ordering
* Error mapping
* Boundary conditions

---

## 12. Prohibited Patterns (Hard No)

* Magic strings
* Boolean flags that encode state
* Implicit defaults that affect behavior
* Silent fallbacks
* TODOs without tickets
* Catch-all `catch (Exception)`

---

## 13. Naming

### Rules

* **Verbs for actions**
* **Nouns for values**
* **No abbreviations unless universal**
* **Names should survive grep**

---

## 14. Gradle Dependencies

### Rules

* **Always use `libs.versions.toml`** — Never include version strings directly in `build.gradle.kts` files
* **Check transitive dependencies before adding libraries** — Before adding a library dependency, verify that an imported module isn't already making it available transitively via `api` declarations
* **Understand `:libraries:utils` exports** — This module exports via `api`: Arrow (core, fx-coroutines, high-arity), http4k (core, config, server-undertow, format-jackson, client-okhttp, template-pebble, platform-k8s, ops-opentelemetry), logging (slf4j, logback, kotlin-logging), and uuid-creator. Its `testFixturesApi` exports junit-jupiter and kotest (runner-junit5, assertions-core).

### Rationale

* Single source of truth for versions prevents drift
* Transitive dependencies via `api` are already on the classpath — re-declaring them adds noise and risks version conflicts
* Smaller build files are easier to maintain

### Examples

```kotlin
// ❌ BAD — hardcoded version
implementation("com.auth0:java-jwt:4.4.0")

// ✅ GOOD — version catalog
implementation(libs.auth0.jwt)
```

```kotlin
// ❌ BAD — re-declaring what utils already exports
dependencies {
    implementation(project(":libraries:utils"))
    implementation(libs.arrow.core)        // redundant
    implementation(libs.http4k.core)       // redundant
    implementation(libs.kotlin.logging.jvm) // redundant
}

// ✅ GOOD — only declare what's not already transitive
dependencies {
    implementation(project(":libraries:utils"))
    // arrow.core, http4k.core, kotlin-logging already available via utils
}
```

---

## 15. External API Resilience

### Rules

* **All calls to external APIs MUST use circuit breakers and retries** — Unless a convincing case can be made that it's not necessary
* **Use the `:libraries:resilience` module** — Provides `resilientCall` and `resilientCallOrRaise` helpers
* **Our own backend systems are NOT external APIs** — PostgREST, internal services, etc. do not require resilience wrappers

### Rationale

External services fail. Network issues, rate limits, and service outages happen regularly. Without resilience patterns:
* Transient failures become permanent failures
* One slow service can cascade and take down the entire application
* Users experience unnecessary errors that retries would have fixed

### External Services Requiring Resilience

* **GEMINI** — Google Gemini AI API
* **YOUTUBE** — YouTube oEmbed API
* **STYTCH** — Stytch authentication service
* **STRIPE** — Stripe payment processing

### Examples

```kotlin
// ❌ BAD — raw API call without resilience
val response = try {
    client(httpRequest)
} catch (e: Exception) {
    raise(CacheError.GeminiError("Failed: ${e.message}"))
}

// ✅ GOOD — wrapped with resilience
val response = resilientCallOrRaise(
    service = ExternalService.GEMINI,
    onError = { CacheError.GeminiError("Failed: ${it.message}") }
) {
    val resp = client(httpRequest)
    if (!resp.status.successful) {
        throw RuntimeException("API returned ${resp.status}")
    }
    resp
}
```

---

## 16. DailyWombat Libraries

### Location

Source for DailyWombat libraries lives by convention in `~/DailyWombat/`, organized by library name:
* `~/DailyWombat/utils/`
* `~/DailyWombat/flyway/`
* `~/DailyWombat/postgrest/`
* `~/DailyWombat/jobs/`
* `~/DailyWombat/jobs-runtime/`
* `~/DailyWombat/runtime/`

### Adding Functionality to a Library

When you need to add functionality to a DailyWombat library:

1. **Add the functionality** — Implement the change in the library source
2. **Add tests** — All new functionality must have tests. All tests must pass.
3. **Bump the version** — Update `version` in `gradle.properties` before publishing
4. **Publish** — Run `gradle publish` to push to GitHub Packages
5. **Push to GitHub** — Commit and push all changes
6. **Update the consumer** — Update `libs.versions.toml` in the app to use the new version
7. **Update README.md** — Document the new functionality and update the version shield
8. **Update WORKLOG.md** — Add technical details of work done (create if needed)

### Publishing Checklist

* [ ] All tests pass (`gradle test`)
* [ ] Version bumped in `gradle.properties`
* [ ] Published to GitHub Packages (`gradle publish`)
* [ ] Changes pushed to GitHub
* [ ] Consumer app updated to new version
* [ ] README.md updated with new functionality
* [ ] Version shield in README.md reflects new version
* [ ] WORKLOG.md updated with technical details

---

## 17. GitHub Actions Workflows

Any changes under `.github/` **must** be validated with security linters before committing.

### Required Tools

Install these tools:

```bash
brew install actionlint zizmor poutine
```

### Before Committing

Run all three linters from the repository root:

```bash
actionlint .github/workflows/*.yml
zizmor .github/workflows/*.yml
poutine analyze_local .
```

All tools must pass with zero errors. Warnings should be reviewed and addressed unless there's a documented reason to suppress.

### What These Tools Check

| Tool | Purpose |
|------|---------|
| **actionlint** | Syntax errors, shellcheck integration, type checking |
| **zizmor** | Security issues: unpinned actions, excessive permissions, template injection, credential leaks |
| **poutine** | Supply chain attacks: injection, untrusted checkouts, self-hosted runner risks |

### Workflow Security Requirements

1. **Pin actions to SHA** - Use full commit hash, not tags: `actions/checkout@34e11487...` not `actions/checkout@v4`
2. **Explicit permissions** - Always include a `permissions:` block with minimum required access
3. **No credential persistence** - Use `persist-credentials: false` on checkout actions
4. **No template injection** - Never use `${{ }}` directly in `run:` blocks; assign to env vars first
5. **No `ls | grep`** - Use `find` or globs for portable file listing

---

## 18. Docker Image Tags

### Rules

* **Never use `latest` tag** — Always use immutable, content-addressable tags
* **Use commit SHA for tags** — `ghcr.io/org/app:abc123def` not `ghcr.io/org/app:latest`
* **Deployments reference specific SHAs** — Image tags in Kubernetes manifests must be commit SHAs

### Rationale

* `latest` is mutable — the same tag can point to different images over time
* Rollbacks are impossible without knowing which image was running
* Debugging production issues requires knowing exactly what code is deployed
* GitOps requires immutable references for reproducibility

### Examples

```yaml
# ❌ BAD — mutable tag
image: ghcr.io/topwombat/nerva-main:latest

# ✅ GOOD — immutable SHA tag
image: ghcr.io/topwombat/nerva-main:db6622b0bd7870a3380dd9cbef02abe56321cbce
```

---

## 19. Bot Instruction Summary (TL;DR)

> If you are a coding bot:
>
> * Encode invariants in types
> * Prefer determinism over convenience
> * Never fabricate JSON
> * Never use `String` for IDs or enums
> * Postgres decides, Kotlin reflects
> * If unsure, make it explicit
