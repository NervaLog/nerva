# Cache Module

YouTube video summaries cache with Gemini AI integration.

## Overview

This module provides:
- Caching of AI-generated YouTube video summaries
- Integration with Google Gemini API for summary generation
- Cache-first retrieval strategy (check cache → generate if miss → store)

## Database Schema

### `cache.video_summaries`

```sql
video_id    TEXT PRIMARY KEY    -- YouTube video ID (11 chars)
summary     JSONB NOT NULL      -- Structured summary content
created_at  TIMESTAMPTZ         -- When cached (default: now())
```

Summaries are **immutable** — once created, never updated.

## Configuration

| Environment Variable | Description | Default |
|---------------------|-------------|---------|
| `GEMINI_API_KEY` | Google AI API key | Required |
| `GEMINI_MODEL` | Gemini model name | `gemini-2.0-flash` |

```kotlin
val config = GeminiConfig(
    apiKey = System.getenv("GEMINI_API_KEY"),
    model = "gemini-2.0-flash"
)
```

## Data Types

### VideoSummary

```kotlin
data class VideoSummary(
    val video_id: String,
    val summary: VideoSummaryContent,
    val created_at: Instant
)
```

### VideoSummaryContent

Structured summary returned by Gemini:

```kotlin
data class VideoSummaryContent(
    val video_metadata: VideoMetadata,
    val key_topics: List<KeyTopic>
)

data class VideoMetadata(
    val title: String,
    val channel: String
)

data class KeyTopic(
    val topic: String,
    val timestamp: String,
    val details: String
)
```

### CacheError

```kotlin
sealed interface CacheError {
    data class GeminiError(val message: String) : CacheError
    data class DatabaseError(val underlying: PostgRestError) : CacheError
    data class InvalidVideoId(val videoId: String) : CacheError
}
```

## Actions

### GetOrSummarize

Main entry point. Checks cache first, generates if missing.

```kotlin
context(client: PostgRestClient, _: Raise<CacheError>)
operator fun invoke(videoId: String, geminiConfig: GeminiConfig): VideoSummary
```

**Usage:**

```kotlin
either {
    context(Postgrest.client(config)) {
        val summary = GetOrSummarize("dQw4w9WgXcQ", geminiConfig)
        // summary.video_id = "dQw4w9WgXcQ"
        // summary.summary.video_metadata.title = "..."
        // summary.summary.key_topics = [...]
    }
}
```

### GetCachedSummary

Retrieve from cache only (no generation).

```kotlin
context(client: PostgRestClient, _: Raise<PostgRestError>)
operator fun invoke(videoId: String): VideoSummary?
```

### GenerateSummary

Call Gemini API to generate summary (no caching).

```kotlin
context(_: Raise<CacheError>)
operator fun invoke(videoId: String, config: GeminiConfig): VideoSummaryContent
```

### CacheSummary

Store summary in database.

```kotlin
context(client: PostgRestClient, _: Raise<PostgRestError>)
operator fun invoke(videoId: String, content: VideoSummaryContent): VideoSummary
```

## Gemini API Integration

The module calls Google's Gemini API with structured output schema enforcement:

**Request:**
```json
{
  "contents": [{ "parts": [{"text": "Analyze the video..."}] }],
  "generationConfig": {
    "responseMimeType": "application/json",
    "responseSchema": {
      "type": "OBJECT",
      "properties": {
        "video_metadata": { ... },
        "key_topics": { ... }
      }
    }
  }
}
```

The schema ensures consistent response structure regardless of video content.

## Error Handling

| Error | When |
|-------|------|
| `InvalidVideoId` | Video ID doesn't match 11-char YouTube format |
| `GeminiError` | API call failed or response parsing failed |
| `DatabaseError` | PostgREST query/insert failed |

## Tests

```bash
./gradlew :modules:cache:test
```

- `video_summaries table is queryable via PostgREST` — verifies schema and PostgREST access

## Dependencies

- `:libraries:postgrest` — Database access
- `:libraries:flyway` — Schema migrations
- `:libraries:utils` — http4k, Jackson, Arrow
