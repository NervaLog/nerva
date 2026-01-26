SET SEARCH_PATH TO ${jobs}, public;

/**
 * Add cap and jitter to exponential backoff.
 *
 * Problems with previous implementation:
 * - No cap: backoff grows unbounded (8.5 hours after 10 attempts)
 * - No jitter: jobs that fail together retry together (thundering herd)
 *
 * Fix:
 * - Add p_max_backoff_seconds parameter (default 900 = 15 minutes)
 * - Add ±25% jitter to spread out retries
 *
 * Formula: min(base * 2^attempts, max_backoff) * (0.75 + random() * 0.5)
 */

DROP FUNCTION IF EXISTS fail_or_retry_job(uuid, text, int, int, text);

CREATE FUNCTION fail_or_retry_job(
    p_job_id uuid,
    p_worker_id text DEFAULT NULL,
    p_max_attempts int DEFAULT 3,
    p_backoff_seconds int DEFAULT 30,
    p_max_backoff_seconds int DEFAULT 900, -- 15 minute cap
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
    v_base_backoff     double precision;
    v_jittered_backoff double precision;
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

        -- Exponential backoff with cap
        v_base_backoff := LEAST(
                p_backoff_seconds * power(2, v_current_attempts),
                p_max_backoff_seconds
                          );

        -- Add ±25% jitter to spread out retries and avoid thundering herd
        -- Formula: base * (0.75 + random() * 0.5) gives range [0.75, 1.25] * base
        v_jittered_backoff := v_base_backoff * (0.75 + random() * 0.5);

        v_backoff_interval := v_jittered_backoff * interval '1 second';
    END IF;

    -- Update the job
    UPDATE jobs
    SET status       = v_new_status,
        attempts     = v_new_attempts,
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

COMMENT ON FUNCTION fail_or_retry_job IS 'Fail or retry a job with capped exponential backoff and jitter. Raises JB001 if not found.';
