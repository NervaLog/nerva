# Resilience Library

Provides retry logic and circuit breaker protection for calls to external APIs.

## Overview

This library wraps Arrow's `arrow-resilience` module to provide:

- **Automatic retries** with exponential backoff and jitter
- **Circuit breakers** that fail fast when services are unhealthy
- **Per-service isolation** — each external service has independent circuit breaker state

## Usage

### Basic Usage (returns Either)

```kotlin
val result = resilientCall(ExternalService.YOUTUBE) {
    client(Request(Method.GET, url))
}

result.fold(
    ifLeft = { error -> handleError(error) },
    ifRight = { response -> processResponse(response) }
)
```

### With Raise Context (raises on failure)

```kotlin
context(Raise<CacheError>)
fun fetchMetadata(videoId: String): Metadata {
    return resilientCallOrRaise(
        service = ExternalService.YOUTUBE,
        onError = { CacheError.YouTubeError(it.message ?: "Unknown") }
    ) {
        val response = client(Request(Method.GET, url))
        if (!response.status.successful) {
            throw RuntimeException("API returned ${response.status}")
        }
        parseResponse(response)
    }
}
```

## External Services

| Service | Max Retries | Initial Delay | Circuit Breaker Opens After |
|---------|-------------|---------------|------------------------------|
| GEMINI  | 2           | 500ms         | 3 failures                   |
| YOUTUBE | 3           | 100ms         | 5 failures                   |
| STYTCH  | 2           | 200ms         | 5 failures                   |
| STRIPE  | 2           | 300ms         | 3 failures                   |

## Circuit Breaker States

- **Closed**: Normal operation, requests pass through
- **Open**: Too many failures, requests fail immediately with `CircuitBreakerOpenException`
- **Half-Open**: After reset timeout, one request is allowed through to test recovery

## Adding a New External Service

1. Add the service to `ExternalService` enum
2. Add configuration in `Resilience.serviceConfigs` map
3. Use `resilientCall` or `resilientCallOrRaise` in your API client
