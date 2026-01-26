# Worklog

Chronological log of completed work items.

---

## 2026-01-23

- Created `:modules:cache` module with database schema for YouTube video summaries
- Added `cache.video_summaries` table (video_id TEXT PK, summary JSONB, created_at TIMESTAMPTZ)
- Created `CacheSchema.kt` with VideoSummaries entity
- Created `VideoSummary` and `VideoSummaryContent` data models
- Added Flyway migrations with epoch millisecond versioning
- Implemented `GetOrSummarize` action — cache-first retrieval with Gemini fallback
- Implemented `GetCachedSummary` action — cache lookup
- Implemented `GenerateSummary` action — Gemini API integration with structured output schema
- Implemented `CacheSummary` action — insert into database
- Added `GeminiConfig` for API configuration
- Added `CacheError` sealed interface for typed error handling
- Created `modules/cache/README.md` with full documentation
- Renamed project from "template" to "nerva" in `settings.gradle.kts`
- Rewrote `README.md` for Nerva project
- Rewrote `CLAUDE.md` for Nerva project
- Added `CODING_STYLE.md` with http4k Jackson rule and Flyway versioning rule
- Created `WORKLOG.md`
- Added `GET /api/v1/summary/{videoId}` endpoint to `:apps:main`
- Added `GeminiConfig` to `AppConfig` with `GEMINI_API_KEY` and `GEMINI_MODEL` env vars
- Created `GetSummary` endpoint handler with proper error responses
- Set up `jvm-test-suite` plugin for integration tests (separate from unit tests)
- Created `GetSummaryIntegrationTest` — end-to-end test covering:
  - Cache miss → Gemini generation → database insert → response
  - Cache hit on subsequent request
  - Invalid video ID error handling
- Documented integration test setup in README
- Fixed Gemini API integration: use full YouTube URL in prompt, add `required` fields to schema
- Updated default model to `gemini-2.5-flash-lite`
- **IAM Phase 1: Google OAuth**
  - Added `StytchConfig.publicToken` for OAuth redirect URLs
  - Added `OAuth.discoveryAuthenticate` API wrapper in `external/stytch`
  - Migration `V1769210222000`: make `email` nullable, add `provider` column to `discovery_requests`
  - Created `RequestOAuthDiscovery` flow with PKCE + Stytch OAuth start URL building
  - Updated `AuthenticateCallback` to dispatch based on token type (discovery vs discovery_oauth)
  - Added `GET /login/google` endpoint for OAuth initiation
  - Updated `DiscoveryRequest` model with `forMagicLink` and `forOAuth` factory methods

---

## 2026-01-24

- **PostgREST Schema Configuration**
  - Added `cache` schema to `PGRST_DB_SCHEMAS` in docker-compose
  - Created migration `V1769220984000__cache__authenticator-grant.sql` for schema access

- **Video Summary URL Field**
  - Added `url` field to `VideoSummary` model (http4k `Uri` type)
  - Created migration `V1769222453000__cache__add-url.sql`
  - Updated `CacheSummary` and `GetOrSummarize` to store/return full YouTube URL

- **Fixed Gemini Video Hallucinations**
  - Changed from text prompt to `file_data` with `mime_type: "video/youtube"` for proper video understanding
  - Added `temperature: 0.0` for deterministic responses
  - Added 3-minute OkHttp read timeout for video processing

- **Model Selection & Token Analysis**
  - Analyzed token consumption rates: Gemini 2.5 ~297 tokens/sec, Gemini 3 ~92 tokens/sec
  - Cost analysis: 2.5-flash-lite cheapest despite 3x tokens (5x lower price per token)
  - Default to `gemini-2.5-flash-lite` for videos < 55 min

- **SummarySource Enum**
  - Created `SummarySource` enum with model names and token rates
  - Added `source` field to `VideoSummary` for tracking which model generated the summary
  - Created migration `V1769227326000__cache__add-model.sql`
  - Uses `@JsonValue` for proper JSON serialization of model names

- **Documentation**
  - Added Gemini token consumption table to README
  - Added "Typed Strings Over Raw Strings" rule to CODING_STYLE.md

- **Hallucination Guardrail**
  - Added `CacheError.ApparentHallucination` error type
  - Created `FetchYouTubeMetadata` action using free YouTube oEmbed endpoint
  - Added title validation in `GetOrSummarize` with fuzzy matching (exact, contains, 50%+ word overlap)
  - Summary is rejected if Gemini returns content for wrong video
  - Added `hallucination_detected` error response in API

- **Schema Improvements**
  - Added `description` fields to JSON schema for better Gemini guidance
  - Improved prompt: "Watch this YouTube video and extract its metadata and key topics."

- **Process**
  - Added WORKLOG update requirement to CLAUDE.md exit criteria

- **Mobile Auth API**
  - Created `/api/v1/auth/magic-link/send` - Send magic link email with deep link URL
  - Created `/api/v1/auth/magic-link/verify` - Verify magic link token, return JWT
  - Created `/api/v1/auth/oauth/start` - Start OAuth flow, return redirect URL
  - Created `/api/v1/auth/oauth/verify` - Verify OAuth callback, return JWT
  - Added Bearer token support to `JwtSession` (reads from Authorization header)
  - Created `docs/FLUTTER_AUTH_INTEGRATION.md` - Complete Flutter integration guide
