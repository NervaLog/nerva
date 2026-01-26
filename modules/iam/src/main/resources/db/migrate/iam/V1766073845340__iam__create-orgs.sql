SET SEARCH_PATH TO ${iam}, extensions;

CREATE TABLE IF NOT EXISTS orgs
(
    id          uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    name        text,
    slug        citext      NOT NULL UNIQUE,
    status      org_status  NOT NULL DEFAULT 'active',

    -- Billing/Limits
    plan_key    text        NOT NULL DEFAULT 'free',
    seats_limit int         NOT NULL DEFAULT 1,
    external_id text UNIQUE, -- Stripe Customer ID mapping

    settings    jsonb       NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS org_membership
(
    org_id           uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    user_id          uuid        NOT NULL REFERENCES orgs (id) ON DELETE CASCADE,
    role             org_role    NOT NULL DEFAULT 'member',
    is_primary_owner boolean     NOT NULL DEFAULT false,

    joined_at        timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (org_id, user_id)
);

-- Partial index ensures only one primary owner per org
CREATE UNIQUE INDEX IF NOT EXISTS org_members_one_primary_owner
    ON org_membership (org_id) WHERE is_primary_owner = true;