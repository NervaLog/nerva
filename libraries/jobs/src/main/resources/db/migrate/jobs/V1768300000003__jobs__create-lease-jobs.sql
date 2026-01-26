SET SEARCH_PATH TO ${jobs}, public;

/**
 * Lease jobs for processing.
 *
 * Atomically selects up to N ready jobs, marks them as 'processing',
 * and assigns them to the worker. Uses FOR UPDATE SKIP LOCKED for
 * concurrent-safe leasing.
 *
 * @param p_worker_id - Unique identifier for the worker
 * @param p_limit - Maximum number of jobs to lease (default: 10)
 * @param p_lease_duration_minutes - How long the lease is valid (default: 2)
 * @param p_job_types - Optional array of job types to filter (NULL = all types)
 * @returns Table of leased jobs
 */
CREATE OR REPLACE FUNCTION lease_jobs(
    p_worker_id text,
    p_limit int DEFAULT 10,
    p_lease_duration_minutes int DEFAULT 2,
    p_job_types text[] DEFAULT NULL
)
    RETURNS TABLE
            (
                id          uuid,
                job_type    text,
                target_type text,
                target_id   uuid,
                params      jsonb,
                priority    int,
                attempts    int
            )
    LANGUAGE plpgsql
AS
$$
BEGIN
    RETURN QUERY
        WITH ready_jobs AS (SELECT j.id
                            FROM jobs j
                            WHERE j.status IN ('pending', 'retrying')
                              AND j.available_at <= now()
                              AND (p_job_types IS NULL OR j.job_type = ANY (p_job_types))
                            ORDER BY j.priority DESC, j.available_at, j.id
                            LIMIT p_limit FOR UPDATE SKIP LOCKED),
             updated AS (
                 UPDATE jobs j
                     SET
                         status = 'processing',
                         lease_owner = p_worker_id,
                         lease_until = now() + (p_lease_duration_minutes || ' minutes')::interval,
                         attempts = j.attempts + 1
                     FROM ready_jobs r
                     WHERE j.id = r.id
                     RETURNING j.*)
        SELECT u.id,
               u.job_type,
               u.target_type,
               u.target_id,
               u.params,
               u.priority,
               u.attempts
        FROM updated u;
END;
$$;

COMMENT ON FUNCTION lease_jobs IS 'Atomically lease jobs for processing with FOR UPDATE SKIP LOCKED';
