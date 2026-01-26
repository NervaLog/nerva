SET search_path TO ${iam_stytch}, extensions;

create or replace function cleanup_discovery_requests(
    p_delete_consumed_older_than interval default interval '7 days'
)
    returns bigint
    language plpgsql
    security definer
    set search_path = ${iam_stytch}, extensions
as
$$
declare
    v_now     timestamptz := now();
    v_deleted bigint;
begin
    -- Clean up discovery requests in two categories:
    --
    -- 1. Expired unconsumed requests (expires_at passed)
    --    These represent abandoned OAuth flows:
    --      - User never clicked the magic link
    --      - User started OAuth but didn't complete it
    --      - Link expired before they could use it
    --
    -- 2. Old consumed requests (consumed_at older than retention period)
    --    These are successfully processed requests kept for audit/debugging.
    --    After the retention period (default 7 days), they can be purged
    --    to prevent unbounded table growth.
    --
    -- This function should be called periodically (e.g., daily cron job)
    -- to maintain database hygiene.
    delete
    from discovery_requests
    where (consumed_at is null and expires_at <= v_now)
       or (consumed_at is not null and consumed_at <= v_now - p_delete_consumed_older_than);

    -- Return count of deleted rows for observability/metrics
    -- If this number is very high, may indicate:
    --   - OAuth conversion rate issues (many expired unconsumed)
    --   - Cleanup running too infrequently (large consumed backlog)
    get diagnostics v_deleted = row_count;
    return v_deleted;
end;
$$;

