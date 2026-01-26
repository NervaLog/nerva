SET search_path TO ${iam_stytch}, extensions;

create or replace function claim_discovery_request(
    p_token text,
    p_lease_seconds int default 60,
    p_lease_owner text default null
)
    returns table
            (
                id               uuid,
                email            citext,
                verifier         text,
                code_challenge   text,
                lease_expires_at timestamptz
            )
    language plpgsql
    security definer
    set search_path = ${iam_stytch}, extensions
as
$$
declare
    v_now           timestamptz := now();
    v_lease_expires timestamptz := v_now + make_interval(secs => p_lease_seconds);
begin
    -- Atomically claim the request by setting lease fields
    -- The WHERE clause ensures we only claim if:
    --   1. Token matches (authorization)
    --   2. Not yet consumed (consumed_at is null)
    --   3. Not expired (expires_at > now())
    --   4. Either:
    --        a) Never leased before (leased_at is null), OR
    --        b) Previous lease expired (lease_expires_at <= now())
    --
    -- If another worker already holds a live lease, this UPDATE matches 0 rows.
    -- This implements distributed locking with automatic recovery from worker crashes.
    return query
        update discovery_requests
            set leased_at = v_now,
                lease_expires_at = v_lease_expires,
                lease_owner = p_lease_owner
            where token = p_token
                and consumed_at is null
                and expires_at > v_now
                and (
                      -- First claim: never leased
                      leased_at is null

                      -- Recovery claim: previous lease expired
                      or lease_expires_at is null
                      or lease_expires_at <= v_now
                      )
            returning
                discovery_requests.id,
                discovery_requests.email,
                discovery_requests.first_name,
                discovery_requests.verifier,
                discovery_requests.code_challenge,
                discovery_requests.lease_expires_at;

    -- If return query yielded 0 rows, worker should:
    --   1. Check if request was already consumed (success case)
    --   2. Check if another worker holds active lease (retry later)
    --   3. Check if request expired (dead letter)
end;
$$;
