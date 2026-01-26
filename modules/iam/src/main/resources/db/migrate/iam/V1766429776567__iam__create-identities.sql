SET SEARCH_PATH TO ${iam}, extensions;

CREATE TABLE IF NOT EXISTS identities
(
    id               uuid PRIMARY KEY       DEFAULT gen_random_uuid(),
    user_id          uuid          NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    provider         auth_provider NOT NULL,
    provider_subject text          NOT NULL,
    email_at_auth    citext, -- Store what the provider claims is their email

    created_at       timestamptz   NOT NULL DEFAULT now(),
    updated_at       timestamptz   NOT NULL DEFAULT now(),
    last_used_at     timestamptz,

    UNIQUE (provider, provider_subject)
);

CREATE INDEX IF NOT EXISTS idx_identities_user_id ON identities (user_id);