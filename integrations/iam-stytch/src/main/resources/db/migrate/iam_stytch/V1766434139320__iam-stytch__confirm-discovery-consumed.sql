SET search_path TO ${iam_stytch}, extensions;

create or replace function confirm_discovery_consumed(
    p_id uuid,
    p_lease_owner text default null
)
    returns void
    language plpgsql
    security definer
    set search_path = ${iam_stytch}, extensions
as
$$
declare
    v_now timestamptz := now();
begin
    -- Mark the discovery request as successfully consumed
    -- This is the final step after a worker successfully processes the request.
    -- The WHERE clause validates several invariants before confirming:
    --   1. Request hasn't already been consumed (consumed_at is null)
    --   2. Request hasn't expired (expires_at > now())
    --   3. Request was actually leased (leased_at is not null)
    --   4. Lease is still valid (lease_expires_at > now())
    --   5. Caller owns the lease (lease_owner matches p_lease_owner)
    --
    -- The verifier is cleared to prevent PKCE replay attacks after consumption.
    update discovery_requests
    set consumed_at = v_now,
        verifier    = null  -- Clear PKCE verifier after successful use
    where id = p_id
      and consumed_at is null
      and expires_at > v_now
      and leased_at is not null
      and (lease_expires_at is null or lease_expires_at > v_now)
      and (p_lease_owner is null or lease_owner is not distinct from p_lease_owner);

    -- If no row was updated, something went wrong:
    --   - Request was already consumed by another worker
    --   - Lease expired before processing completed (worker too slow)
    --   - Lease owner doesn't match (wrong worker trying to confirm)
    if not found then
        raise exception 'Cannot confirm discovery request: already consumed, lease expired, or lease owner mismatch'
            using errcode = 'IS001',
                detail = format('Request ID: %s, Lease owner: %s', p_id, p_lease_owner);
    end if;
end;
$$;
