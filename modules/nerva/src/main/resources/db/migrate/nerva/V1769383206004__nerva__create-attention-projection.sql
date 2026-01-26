SET search_path TO ${nerva}, extensions;

-- Collapsed/deduped attention items (projection from events)
-- Multiple events can collapse into a single attention item
CREATE TABLE IF NOT EXISTS attention_projection
(
    id              uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    org_id          uuid        NOT NULL REFERENCES ${iam}.orgs (id),

    -- Deterministic ID for collapse window (sha256 of collapse key components)
    -- Used for ON CONFLICT upsert
    attention_id    text        NOT NULL,

    -- Classification
    attention_kind  attention_kind NOT NULL DEFAULT 'batch',
    status          attention_status NOT NULL DEFAULT 'pending',

    -- Rendered content for push notification
    title           text        NOT NULL,
    body            text,
    deeplink_url    text,

    -- Collapse tracking
    event_count     int         NOT NULL DEFAULT 1,
    first_event_at  timestamptz NOT NULL DEFAULT now(),
    last_event_at   timestamptz NOT NULL DEFAULT now(),

    -- Source events (for audit trail)
    event_ids       uuid[]      NOT NULL DEFAULT '{}',

    -- Lifecycle
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    delivered_at    timestamptz,
    actioned_at     timestamptz,
    expires_at      timestamptz,

    -- Unique constraint for deterministic collapse
    UNIQUE (org_id, attention_id)
);

-- Index for querying pending items by org
CREATE INDEX IF NOT EXISTS attention_org_status_idx
    ON attention_projection (org_id, status) WHERE status = 'pending';

-- Index for expiration cleanup
CREATE INDEX IF NOT EXISTS attention_expires_idx
    ON attention_projection (expires_at) WHERE status = 'pending' AND expires_at IS NOT NULL;

-- Grant permissions
GRANT SELECT ON attention_projection TO web_anon;
GRANT SELECT, INSERT, UPDATE ON attention_projection TO authenticated;
