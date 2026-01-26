# PostgREST

Type-safe PostgREST client with Arrow context receivers for typed error handling.

## Design Principle

**Never use JDBC directly.** All database access goes through PostgREST:

- Leverages PostgreSQL RLS (row-level security)
- Type-safe via http4k lenses
- Forces clean separation between app and database logic

## Components

### PostgRestClient

Core client for making PostgREST requests:

```kotlin
val client = Postgrest.client(PostgRestConfig(
    url = "http://localhost:3000",
    apiKey = "your-api-key"
))

context(client) {
    // Make PostgREST calls
}
```

### PostgRestConfig

Configuration for connecting to PostgREST:

```kotlin
data class PostgRestConfig(
    val url: String,
    val apiKey: String,
    val schema: String = "public"
)
```

### PostgRestEntity

Base class for PostgREST entity companions with lens definitions.

### PostgRestError

Typed error hierarchy:

```kotlin
sealed interface PostgRestError {
    data class HttpError(val status: Status, val body: String)
    data class ParseError(val message: String, val cause: Throwable?)
    data class CustomError(val code: String, val message: String)
}
```

## Actions

### Select

Query entities from a table:

```kotlin
context(pgRest: PostgRestClient, _: Raise<PostgRestError>) {
    val users = with(User.lens) {
        pgRest(IamSchema.Users, Select<User> {
            eq(User::email, email)
        })
    }
}
```

### Insert

Insert entities into a table:

```kotlin
context(pgRest: PostgRestClient, _: Raise<PostgRestError>) {
    val inserted = with(User.lens) {
        pgRest(IamSchema.Users, Insert(user))
    }
}
```

### Update

Update entities in a table:

```kotlin
context(pgRest: PostgRestClient, _: Raise<PostgRestError>) {
    pgRest(IamSchema.Users, Update(user) {
        eq(User::id, userId)
    })
}
```

### RpcPost / RpcGet

Call stored procedures:

```kotlin
context(pgRest: PostgRestClient, _: Raise<PostgRestError>) {
    val result = pgRest(
        MySchema.MyStoredProc,
        RpcPost(
            inputLens = inputLens,
            outputLens = outputLens,
            input = params
        )
    )
}
```

## Headers

### Prefer

PostgREST `Prefer` header helpers:

```kotlin
Prefer.returnRepresentation()   // Return inserted/updated rows
Prefer.returnMinimal()          // Return nothing
Prefer.count()                  // Include count header
```

## Tests

**No tests currently exist for this module.**

Tests for PostgREST functionality are integrated into module-level tests that use the `PostgrestContainer` test fixture.

### Test Fixtures

```kotlin
dependencies {
    testImplementation(testFixtures(project(":libraries:postgrest")))
}
```

Provides:

- `PostgrestContainer` - TestContainers setup with PostgreSQL + PostgREST
- `TestContainers.start()` / `TestContainers.stop()` - Lifecycle management
- `TestContainers.postgRestClient()` - Pre-configured client

```bash
./gradlew :libraries:postgrest:test
```
