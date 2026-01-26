SET SEARCH_PATH TO ${iam}, extensions;

CREATE TABLE IF NOT EXISTS users
(
    id             uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    email          citext UNIQUE,
    email_verified boolean     NOT NULL DEFAULT false,
    first_name     text,
    last_name      text,
    avatar_url     text,
    status         user_status NOT NULL DEFAULT 'active',
    metadata       jsonb       NOT NULL DEFAULT '{}',

    last_login_at  timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);

create unique index if not exists users_email_unique
    on users (email) where email is not null;