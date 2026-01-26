SET SEARCH_PATH TO ${jobs}, public;

/**
 * Separate lease_count from attempts.
 *
 * Previously, `attempts` was incremented on every lease. This meant that
 * worker crashes (stale leases) would burn retry budget even though the
 * job never actually ran.
 *
 * Now:
 * - `lease_count` tracks how many times the job was leased (observability)
 * - `attempts` tracks actual execution failures (retry budget)
 *
 * Stale lease recovery no longer affects retry budget.
 */

-- Add lease_count column
ALTER TABLE jobs
    ADD COLUMN lease_count int NOT NULL DEFAULT 0;
ALTER TABLE jobs_dead_letter
    ADD COLUMN lease_count int NOT NULL DEFAULT 0;

COMMENT ON COLUMN jobs.lease_count IS 'Number of times this job has been leased for processing';
COMMENT ON COLUMN jobs.attempts IS 'Number of actual execution failures (not stale leases)';

-- Update lease_jobs to increment lease_count instead of attempts
DROP FUNCTION IF EXISTS lease_jobs(text, int, int, text[]);

CREATE FUNCTION lease_jobs(
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
                attempts    int,
                lease_count int
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
                         lease_count = j.lease_count + 1 -- Increment lease_count, NOT attempts
                     FROM ready_jobs r
                     WHERE j.id = r.id
                     RETURNING j.*)
        SELECT u.id,
               u.job_type,
               u.target_type,
               u.target_id,
               u.params,
               u.priority,
               u.attempts,
               u.lease_count
        FROM updated u;
END;
$$;

COMMENT ON FUNCTION lease_jobs IS 'Atomically lease jobs for processing. Increments lease_count (not attempts).';

-- Update fail_or_retry_job to increment attempts on failure
DROP FUNCTION IF EXISTS fail_or_retry_job(uuid, text, int, int, text);

CREATE FUNCTION fail_or_retry_job(
    p_job_id uuid,
    p_worker_id text DEFAULT NULL,
    p_max_attempts int DEFAULT 3,
    p_backoff_seconds int DEFAULT 30,
    p_error text DEFAULT NULL
)
    RETURNS text
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_current_attempts int;
    v_new_status       job_status;
    v_new_attempts     int;
    v_backoff_interval interval;
BEGIN
    -- Get current attempts
    SELECT attempts
    INTO v_current_attempts
    FROM jobs
    WHERE id = p_job_id
      AND status = 'processing'
      AND (p_worker_id IS NULL OR lease_owner = p_worker_id);

    IF v_current_attempts IS NULL THEN
        RAISE EXCEPTION 'job_not_found'
            USING ERRCODE = 'JB001';
    END IF;

    -- This IS an actual execution failure, so increment attempts
    v_new_attempts := v_current_attempts + 1;

    -- Decide: retry or fail permanently
    IF v_new_attempts >= p_max_attempts THEN
        v_new_status := 'failed';
        v_backoff_interval := NULL;
    ELSE
        v_new_status := 'retrying';
        -- Exponential backoff: base * 2^attempts
        v_backoff_interval := (p_backoff_seconds * power(2, v_current_attempts)) * interval '1 second';
    END IF;

    -- Update the job
    UPDATE jobs
    SET status       = v_new_status,
        attempts     = v_new_attempts, -- Increment attempts here, on actual failure
        lease_owner  = NULL,
        lease_until  = NULL,
        last_error   = p_error,
        available_at = CASE
                           WHEN v_new_status = 'retrying' THEN now() + v_backoff_interval
                           ELSE available_at
            END
    WHERE id = p_job_id;

    RETURN v_new_status::text;
END;
$$;

COMMENT ON FUNCTION fail_or_retry_job IS 'Fail or retry a job. Increments attempts on actual failure. Raises JB001 if not found.';
