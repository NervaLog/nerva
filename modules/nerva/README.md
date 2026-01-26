# Nerva Module

Core module for Nerva's event notification system. Handles event ingestion, attention projection, and push notification delivery.

## Schema

The `nerva` schema owns:

### Enums
- `event_type` - Classification of incoming events (calendar_event, email_received, slack_message, etc.)
- `attention_kind` - Priority level (immediate, soon, batch, info)
- `attention_status` - Lifecycle state (pending, delivered, dismissed, actioned, expired)

### Tables
- `events` - Immutable journal of ingested events (append-only)
- `attention_projection` - Collapsed/deduped attention items ready for delivery
- `device_endpoints` - Push notification device tokens (FCM/APNS)
- `api_keys` - API keys for SaaS authentication

### Stored Procedures
- `ingest_event` - Atomic event ingestion: insert event → upsert attention → enqueue job
- `validate_api_key` - Validates Bearer tokens and returns org context
- `render_attention_payload` - Formats attention item as push notification payload

## Actions

### Event Ingestion
```kotlin
context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
IngestEvent(IngestEventInput(
    orgId = orgId,
    provider = "google_calendar",
    externalId = "event_123",
    eventType = EventType.CALENDAR_EVENT,
    title = "Meeting in 5 minutes",
    attentionKind = AttentionKind.IMMEDIATE
))
```

### API Key Validation
```kotlin
context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
when (val result = ValidateApiKey(apiKey)) {
    is ApiKeyValidation.Valid -> result.orgId
    is ApiKeyValidation.Invalid -> // handle error
}
```

### Attention Queries
```kotlin
context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
val pending = GetPendingAttention(orgId)
val item = GetAttentionById(attentionId)
```

## Auth

The module provides `ApiKeyAuthFilter` for protecting API endpoints:

```kotlin
ApiKeyAuthFilter(pgRest).then(
    routes(
        context(pgRest) { IngestEvents() }
    )
)
```

API keys use Bearer token authentication:
```
Authorization: Bearer nv_abc12345...
```

## Job Handlers

### DeliverAttentionJob
Handles push notification delivery for attention items:
1. Fetches attention item
2. Renders push payload via stored proc
3. Sends to all registered device endpoints
4. Marks as delivered

The push adapter is pluggable - defaults to `StubPushAdapter` for development.

## Collapse/Dedup Logic

Events are collapsed into attention items using a deterministic window:
- 5-minute windows by default
- Collapse key = `org_id|collapse_key|window_start` (SHA256 hashed)
- Multiple events in same window → single attention item with incremented count

## API Endpoints

### POST /api/v1/events
Ingest an event for processing.

Request:
```json
{
  "provider": "google_calendar",
  "external_id": "event_abc123",
  "event_type": "calendar_event",
  "title": "Meeting with Bob",
  "attention_kind": "immediate",
  "payload": {}
}
```

Response:
```json
{
  "event_id": "uuid",
  "attention_id": "uuid",
  "was_created": true,
  "job_id": "uuid"
}
```
