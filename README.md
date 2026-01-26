# Nerva

A YouTube exo-brain — backend service that generates, caches, and serves AI-powered summaries of YouTube videos.

## Quick Start

```bash
# Start PostgreSQL + PostgREST
cd docker-compose && docker compose up -d

# Build
./gradlew build

# Run API server
./gradlew :apps:main:run
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Mobile / Desktop Clients                │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                         :apps:main                              │
│                      (HTTP API Server)                          │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                         PostgREST                               │
│                    (REST API for Postgres)                      │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                         PostgreSQL                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │
│  │    cache    │  │     iam     │  │    jobs     │             │
│  │   schema    │  │   schema    │  │   schema    │             │
│  └─────────────┘  └─────────────┘  └─────────────┘             │
└─────────────────────────────────────────────────────────────────┘
```

## Module Structure

### Libraries (`:libraries:*`)
Reusable infrastructure with no business logic.

| Module | Purpose |
|--------|---------|
| `utils` | Http4k helpers, logging, value types |
| `postgrest` | Type-safe PostgREST client with Arrow context receivers |
| `flyway` | Multi-module migration system |
| `jobs` | Background job queue schema |
| `jobs-runtime` | Job processor runtime |

### Modules (`:modules:*`)
Core business domains. Each owns a PostgreSQL schema.

| Module | Schema | Purpose |
|--------|--------|---------|
| `cache` | `cache` | YouTube video summaries (video_id -> JSONB) |
| `iam` | `iam` | Users, orgs, authentication |

### External (`:external:*`)
SDK wrappers for third-party services.

| Module | Service |
|--------|---------|
| `stripe` | Payment webhooks |
| `stytch` | Authentication |

### Apps (`:apps:*`)
Runnable applications.

| App | Purpose |
|-----|---------|
| `main` | Primary HTTP API server |

## API

### GET /api/v1/summary/{videoId}

Get or generate a summary for a YouTube video.

**Request:**
```
GET /api/v1/summary/dQw4w9WgXcQ
```

**Success Response (200):**
```json
{
  "video_id": "dQw4w9WgXcQ",
  "summary": {
    "video_metadata": {
      "title": "Rick Astley - Never Gonna Give You Up",
      "channel": "Rick Astley"
    },
    "key_topics": [
      {
        "topic": "Introduction",
        "timestamp": "0:00",
        "details": "Opening sequence with iconic synth melody"
      }
    ]
  },
  "created_at": "2026-01-23T12:00:00Z"
}
```

**Error Responses:**

| Status | Error | Description |
|--------|-------|-------------|
| 400 | `invalid_video_id` | Video ID doesn't match YouTube format (11 chars) |
| 502 | `generation_failed` | Gemini API call failed |
| 502 | `hallucination_detected` | Summary appears to be for wrong video (title mismatch) |
| 500 | `database_error` | Database operation failed |

## Database Schema

### `cache.video_summaries`

```sql
video_id    TEXT PRIMARY KEY    -- YouTube video ID
summary     JSONB NOT NULL      -- AI-generated summary
created_at  TIMESTAMPTZ         -- When cached
```

Summaries are **immutable** — once created, never updated.

## Development

### Prerequisites
- JDK 21+
- Docker (for PostgreSQL)

### Commands

```bash
./gradlew build                    # Build all
./gradlew test                     # Run all tests
./gradlew :modules:cache:test      # Test specific module
./gradlew clean                    # Clean
```

### Integration Tests

Integration tests live in `apps/main/src/integrationTest/` and require external services (Gemini API, PostgreSQL via TestContainers).

```bash
# Run integration tests (requires GEMINI_API_KEY)
GEMINI_API_KEY=your-key ./gradlew :apps:main:integrationTest
```

Integration tests are **not** run as part of `./gradlew check` — they must be invoked explicitly.

#### GetSummaryIntegrationTest

End-to-end test for the `/api/v1/summary/{videoId}` endpoint:

1. Verifies video is not cached initially
2. Generates summary via Gemini API and returns it
3. Verifies summary is now cached in database
4. Returns cached summary on second request (no Gemini call)
5. Returns 400 for invalid video IDs

### Database Migrations

Migrations use Flyway with epoch millisecond versioning:

```
V{epoch_millis}__{schema}__{description}.sql
```

Example: `V1769193718000__cache__create-tables.sql`

Location: `modules/{name}/src/main/resources/db/migrate/{schema}/`

## Key Patterns

### PostgREST Only
All database access goes through PostgREST. Never use JDBC directly.

### Context Receivers
Service boundaries use Arrow's `Raise` for typed error handling:

```kotlin
context(Raise<CacheError>, PostgRestClient)
fun getSummary(videoId: String): VideoSummary?
```

### Actions as Objects
Business operations are `object` with `operator fun invoke()`:

```kotlin
object GetVideoSummary {
    context(client: PostgRestClient, _: Raise<PostgRestError>)
    operator fun invoke(videoId: String): VideoSummary? {
        // implementation
    }
}
```

## Mobile Authentication API

For Flutter/mobile apps that can't use HttpOnly cookies. Returns JWT tokens in response body.

See [docs/FLUTTER_AUTH_INTEGRATION.md](docs/FLUTTER_AUTH_INTEGRATION.md) for complete Flutter integration guide.

### POST /api/v1/auth/magic-link/send

Send a magic link email.

```json
{
  "email": "user@example.com",
  "deep_link_url": "nerva://auth/callback"
}
```

### POST /api/v1/auth/magic-link/verify

Verify magic link token from deep link callback.

```json
{
  "discovery_token": "...",
  "stytch_token": "...",
  "stytch_token_type": "discovery"
}
```

### POST /api/v1/auth/oauth/start

Start OAuth flow (Google/Microsoft).

```json
{
  "provider": "google",
  "redirect_url": "nerva://auth/callback"
}
```

Response:
```json
{
  "oauth_url": "https://api.stytch.com/...",
  "discovery_token": "..."
}
```

### POST /api/v1/auth/oauth/verify

Verify OAuth callback.

```json
{
  "discovery_token": "...",
  "stytch_token": "...",
  "stytch_token_type": "discovery_oauth"
}
```

### Auth Response Format

All verify endpoints return:

```json
{
  "token": "eyJ...",
  "user": {
    "id": "uuid",
    "email": "user@example.com",
    "org_id": "uuid",
    "org_name": "My Org",
    "org_slug": "my-org",
    "role": "owner"
  }
}
```

Use the `token` in subsequent requests as `Authorization: Bearer <token>`.

## Configuration

Environment variables (`.env` files, gitignored):

| Variable | Description | Required |
|----------|-------------|----------|
| `SERVICE_PORT` | HTTP server port | Yes |
| `HEALTH_PORT` | Health check port | Yes |
| `ORIGIN` | Server origin URL | Yes |
| `JWT_SECRET` | JWT signing secret | Yes |
| `PG_REST_URL` | PostgREST endpoint | Yes |
| `FLYWAY_HOST` | PostgreSQL host | Yes |
| `FLYWAY_PORT` | PostgreSQL port | Yes |
| `FLYWAY_DB` | Database name | Yes |
| `FLYWAY_USER` | Database user | Yes |
| `FLYWAY_PASSWORD` | Database password | Yes |
| `GEMINI_API_KEY` | Google AI API key | Yes |
| `STYTCH_PROJECT_ID` | Stytch project ID | Yes |
| `STYTCH_SECRET` | Stytch secret | Yes |

## Gemini Video Token Consumption

Video summarization token usage varies by model family:

| Model Family | Tokens/Second | Tokens/Minute | Max Video Duration |
|-------------|---------------|---------------|-------------------|
| Gemini 2.5 (flash-lite, flash, pro) | ~297 | ~17,800 | ~55 min |
| Gemini 3 (flash-preview, pro-preview) | ~92 | ~5,500 | ~180 min |

Default model selection: `gemini-2.5-flash-lite` for videos under 55 minutes (cheapest per minute despite higher token count due to lower price per token).

## Hallucination Detection

Before caching a generated summary, the system validates it against YouTube metadata (fetched via free oEmbed API). If the summary title doesn't match the actual video title, it's rejected as a potential hallucination. Title matching uses fuzzy logic: exact match, containment, or 50%+ word overlap.

## Tech Stack

- **Language**: Kotlin 2.2+ with context receivers
- **HTTP**: http4k
- **Database**: PostgreSQL 18 via PostgREST
- **Error Handling**: Arrow
- **JSON**: Jackson (via http4k)
- **Testing**: JUnit 5 + Kotest + TestContainers
- **Build**: Gradle 8.x
