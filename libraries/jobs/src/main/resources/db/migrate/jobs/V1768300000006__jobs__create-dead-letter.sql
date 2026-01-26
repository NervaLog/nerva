SET SEARCH_PATH TO ${jobs}, public;

/**
 * Move failed jobs to the dead letter queue.
 *
 * @param p_job_ids - Array of job IDs to move
 * @returns Number of jobs moved
 */
CREATE OR REPLACE FUNCTION move_to_dead_letter(
    p_job_ids uuid[]
)
    RETURNS int
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_moved int;
BEGIN
    -- Insert into dead letter queue
    INSERT INTO jobs_dead_letter
    SELECT *
    FROM jobs
    WHERE id = ANY (p_job_ids)
      AND status = 'failed';

    GET DIAGNOSTICS v_moved = ROW_COUNT;

    -- Update status to 'dead' and keep in main table for reference
    UPDATE jobs
    SET status = 'dead'
    WHERE id = ANY (p_job_ids)
      AND status = 'failed';

    RETURN v_moved;
END;
$$;

/**
 * Find stale jobs (processing with expired leases).
 *
 * These are jobs where the worker crashed or timed out.
 * They should be released back to pending/retrying.
 *
 * @param p_stale_threshold_minutes - How long past lease_until to consider stale
 * @returns Table of stale jobs
 */
CREATE OR REPLACE FUNCTION find_stale_jobs(
    p_stale_threshold_minutes int DEFAULT 5
)
    RETURNS TABLE
            (
                id          uuid,
                job_type    text,
                target_type text,
                target_id   uuid,
                lease_owner text,
                lease_until timestamptz,
                attempts    int
            )
    LANGUAGE plpgsql
AS
$$
BEGIN
    RETURN QUERY
        SELECT j.id,
               j.job_type,
               j.target_type,
               j.target_id,
               j.lease_owner,
               j.lease_until,
               j.attempts
        FROM jobs j
        WHERE j.status = 'processing'
          AND j.lease_until IS NOT NULL
          AND j.lease_until < now() - (p_stale_threshold_minutes || ' minutes')::interval;
END;
$$;

/**
 * Release a stale job back to the queue.
 *
 * @param p_job_id - The job to release
 * @returns true if released, false otherwise
 */
CREATE OR REPLACE FUNCTION release_stale_job(
    p_job_id uuid
)
    RETURNS boolean
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_updated boolean;
BEGIN
    UPDATE jobs
    SET status       = 'retrying',
        lease_owner  = NULL,
        lease_until  = NULL,
        available_at = now(),
        last_error   = 'Released: worker lease expired'
    WHERE id = p_job_id
      AND status = 'processing';

    GET DIAGNOSTICS v_updated = ROW_COUNT;
    RETURN v_updated > 0;
END;
$$;

COMMENT ON FUNCTION move_to_dead_letter IS 'Move failed jobs to dead letter queue';
COMMENT ON FUNCTION find_stale_jobs IS 'Find jobs with expired leases (crashed workers)';
COMMENT ON FUNCTION release_stale_job IS 'Release a stale job back to the queue';
