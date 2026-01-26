SET search_path TO ${nerva}, extensions;

-- API keys for SaaS authentication (webhooks, mobile, frontend)
CREATE TABLE IF NOT EXISTS api_keys
(
    id              uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    org_id          uuid        NOT NULL REFERENCES ${iam}.orgs (id),

    -- Key identification
    key_prefix      text        NOT NULL,   -- First 8 chars of key for display (e.g. 'nv_abc123')
    key_hash        text        NOT NULL,   -- SHA256 hash of full key

    -- Metadata
    name            text        NOT NULL,   -- Human-friendly name
    description     text,

    -- Permissions (for future use)
    scopes          text[]      NOT NULL DEFAULT '{}',

    -- Lifecycle
    created_at      timestamptz NOT NULL DEFAULT now(),
    last_used_at    timestamptz,
    expires_at      timestamptz,
    revoked_at      timestamptz,

    -- Unique prefix per org (prefixes should be globally unique but indexed per org)
    UNIQUE (org_id, key_prefix)
);

-- Index for key lookup during auth
CREATE INDEX IF NOT EXISTS api_keys_prefix_idx
    ON api_keys (key_prefix) WHERE revoked_at IS NULL;

-- Grant permissions
GRANT SELECT ON api_keys TO web_anon;
GRANT SELECT, INSERT, UPDATE ON api_keys TO authenticated;
