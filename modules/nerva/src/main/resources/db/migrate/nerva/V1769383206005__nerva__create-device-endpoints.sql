SET search_path TO ${nerva}, extensions;

-- Device push notification endpoints
CREATE TABLE IF NOT EXISTS device_endpoints
(
    id              uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    org_id          uuid        NOT NULL REFERENCES ${iam}.orgs (id),
    user_id         uuid        NOT NULL REFERENCES ${iam}.users (id),

    -- Device identification
    device_token    text        NOT NULL,   -- FCM/APNS token
    platform        text        NOT NULL,   -- 'ios', 'android', 'web'
    device_name     text,                   -- User-friendly device name

    -- Push configuration
    push_enabled    boolean     NOT NULL DEFAULT true,

    -- Lifecycle
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    last_push_at    timestamptz,

    -- Unique device token per platform
    UNIQUE (platform, device_token)
);

-- Index for querying by org/user
CREATE INDEX IF NOT EXISTS device_endpoints_org_user_idx
    ON device_endpoints (org_id, user_id) WHERE push_enabled = true;

-- Grant permissions
GRANT SELECT ON device_endpoints TO web_anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON device_endpoints TO authenticated;
