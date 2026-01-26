# Utils

Common utilities for HTTP4k, encoding, value types, and miscellaneous helpers.

## Components

### Value Types

Type-safe wrappers for common value types:

```kotlin
Email("user@example.com")
Slug("my-org-slug")
```

### Encoding

Base64 and other encoding utilities:

```kotlin
Encoding.base64Encode(bytes)
Encoding.base64Decode(string)
```

### ChaCha20

Cryptographic utilities for ChaCha20 encryption.

### HTTP4k Helpers

#### ViewLenses

Pebble template rendering with hot-reload support:

```kotlin
// Hot reload for development
val renderer = ViewLenses.hotReload(isTest = false)

// Production (cached)
val renderer = ViewLenses.cached()
```

#### HttpEndpoint / ApiError

Typed API endpoint and error handling utilities.

#### BoundaryExceptionFilter

HTTP4k filter for handling exceptions at API boundaries.

#### LogEvent

Structured logging helpers for HTTP4k.

#### Origin

HTTP origin value type for OAuth callbacks:

```kotlin
val origin = Origin(Uri.of("https://example.com"))
```

### Seeds

Test data generation utilities.

### US Geo Utils

US state and geographic utilities.

## Tests

Location: `src/test/kotlin/dev/dailywombat/utils/http4k/`

### PebbleTemplatesTest (1 test)

| Test                             | What it validates                               |
|----------------------------------|-------------------------------------------------|
| `Test Pebble Dev and Test Setup` | Hot-reload template rendering with file changes |

```bash
./gradlew :libraries:utils:test
```
