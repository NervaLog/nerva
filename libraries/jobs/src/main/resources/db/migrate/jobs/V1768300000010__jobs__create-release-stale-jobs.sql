SET SEARCH_PATH TO ${jobs}, public;

/**
 * Release jobs with expired leases back to the queue.
 *
 * When a worker crashes or times out, jobs it was processing become "stale" -
 * they're stuck in 'processing' status with an expired lease_until timestamp.
 * This function finds those jobs and releases them for other workers to pick up.
 *
 * Stale jobs are NOT counted as failed attempts - the job didn't fail,
 * the worker died. The job may succeed when picked up again.
 *
 * @param p_limit - Maximum number of stale jobs to release (default: 100)
 * @returns Number of jobs released
 */
CREATE FUNCTION release_stale_jobs(
    p_limit int DEFAULT 100
)
    RETURNS int
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_released int;
BEGIN
    WITH stale AS (SELECT id
                   FROM jobs
                   WHERE status = 'processing'
                     AND lease_until IS NOT NULL
                     AND lease_until < now()
                   ORDER BY lease_until
                   LIMIT p_limit FOR UPDATE SKIP LOCKED)
    UPDATE jobs j
    SET status       = 'retrying',
        lease_owner  = NULL,
        lease_until  = NULL,
        available_at = now(), -- Available immediately
        last_error   = COALESCE(last_error, '') ||
                       CASE WHEN last_error IS NOT NULL THEN E'\n' ELSE '' END ||
                       '[stale] Worker lease expired at ' || lease_until::text
    FROM stale s
    WHERE j.id = s.id;

    GET DIAGNOSTICS v_released = ROW_COUNT;
    RETURN v_released;
END;
$$;

COMMENT ON FUNCTION release_stale_jobs IS 'Release jobs with expired leases back to the queue for reprocessing';
