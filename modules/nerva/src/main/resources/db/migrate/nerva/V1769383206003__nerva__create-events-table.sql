SET search_path TO ${nerva}, extensions;

-- Raw events from external sources (append-only journal)
CREATE TABLE IF NOT EXISTS events
(
    id              uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    org_id          uuid        NOT NULL REFERENCES ${iam}.orgs (id),

    -- External source identification for idempotency
    provider        text        NOT NULL,   -- e.g. 'google_calendar', 'gmail', 'slack'
    external_id     text        NOT NULL,   -- Provider's unique ID for this event

    -- Event classification
    event_type      event_type  NOT NULL,

    -- Event payload (provider-specific structure)
    payload         jsonb       NOT NULL DEFAULT '{}',

    -- Metadata
    occurred_at     timestamptz NOT NULL DEFAULT now(),  -- When the event actually happened
    ingested_at     timestamptz NOT NULL DEFAULT now(),  -- When we received it

    -- Unique constraint for idempotent ingestion
    UNIQUE (org_id, provider, external_id)
);

-- Index for querying by org and time
CREATE INDEX IF NOT EXISTS events_org_time_idx
    ON events (org_id, occurred_at DESC);

-- Index for querying by provider
CREATE INDEX IF NOT EXISTS events_provider_idx
    ON events (provider, external_id);

-- Grant permissions
GRANT SELECT ON events TO web_anon;
GRANT SELECT, INSERT ON events TO authenticated;
