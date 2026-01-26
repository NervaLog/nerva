SET search_path TO ${iam_stytch}, extensions;

-- Fix claim_discovery_request to include first_name in return table
-- and properly qualify column references to avoid ambiguity
-- Must drop first because return type is changing
DROP FUNCTION IF EXISTS claim_discovery_request(text, int, text);

CREATE OR REPLACE FUNCTION claim_discovery_request(
    p_token text,
    p_lease_seconds int default 60,
    p_lease_owner text default null
)
    RETURNS TABLE
            (
                id               uuid,
                email            citext,
                first_name       text,
                verifier         text,
                code_challenge   text,
                lease_expires_at timestamptz
            )
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = ${iam_stytch}, extensions
AS
$$
DECLARE
    v_now           timestamptz := now();
    v_lease_expires timestamptz := v_now + make_interval(secs => p_lease_seconds);
BEGIN
    RETURN QUERY
        UPDATE discovery_requests dr
            SET leased_at = v_now,
                lease_expires_at = v_lease_expires,
                lease_owner = p_lease_owner
            WHERE dr.token = p_token
                AND dr.consumed_at IS NULL
                AND dr.expires_at > v_now
                AND (
                      dr.leased_at IS NULL
                      OR dr.lease_expires_at IS NULL
                      OR dr.lease_expires_at <= v_now
                      )
            RETURNING
                dr.id,
                dr.email,
                dr.first_name,
                dr.verifier,
                dr.code_challenge,
                dr.lease_expires_at;
END;
$$;
