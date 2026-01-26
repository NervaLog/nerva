SET search_path TO ${iam_stytch}, extensions;

create table if not exists discovery_requests
(
    id               uuid primary key     default gen_random_uuid(),

    -- Public-facing, unguessable token placed in the magic link
    token            text        not null,
    redirect_to      text        not null,

    created_at       timestamptz not null default now(),
    expires_at       timestamptz not null,

    -- Who this request is for
    email            citext      not null,
    first_name       text,

    -- PKCE-ish bits / secret material
    verifier         text, -- treat as secret; will be nulled on consume
    code_challenge   text,

    -- Lease semantics
    leased_at        timestamptz,
    lease_expires_at timestamptz,
    lease_owner      text, -- opaque: instance id / request id / stytch session id

    -- Terminal state
    consumed_at      timestamptz,

    -- Invariants
    constraint discovery_expires_after_created
        check (expires_at > created_at),

    constraint discovery_lease_consistency
        check (
            (leased_at is null and lease_expires_at is null and lease_owner is null)
                or (leased_at is not null and lease_expires_at is not null)
            ),

    constraint discovery_lease_expires_after_lease
        check (lease_expires_at is null or lease_expires_at > leased_at),

    constraint discovery_consumed_requires_lease
        check (consumed_at is null or leased_at is not null),

    constraint discovery_not_consumed_before_created
        check (consumed_at is null or consumed_at >= created_at)
);

-- Token is the real identifier in the link; make it unique.
create unique index if not exists discovery_requests_token_uq
    on discovery_requests (token);

-- Typical query patterns
create index if not exists discovery_requests_email_idx
    on discovery_requests (email);

create index if not exists discovery_requests_expires_at_idx
    on discovery_requests (expires_at);

create index if not exists discovery_requests_lease_expires_at_idx
    on discovery_requests (lease_expires_at);

create index if not exists discovery_requests_consumed_at_idx
    on discovery_requests (consumed_at);
