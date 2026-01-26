SET SEARCH_PATH TO ${jobs}, public;

/**
 * Update fail_or_retry_job to raise a custom error code when job not found,
 * instead of returning NULL. This allows the Kotlin side to distinguish
 * between "job not found" and actual database errors.
 *
 * Also changes return type from job_status to text for easier Kotlin deserialization.
 */

-- Must drop first because we're changing the return type
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
        -- Job not found or not owned by this worker
        RAISE EXCEPTION 'job_not_found'
            USING ERRCODE = 'JB001';
    END IF;

    -- Decide: retry or fail permanently
    IF v_current_attempts >= p_max_attempts THEN
        v_new_status := 'failed';
        v_backoff_interval := NULL;
    ELSE
        v_new_status := 'retrying';
        -- Exponential backoff: base * 2^(attempts-1)
        v_backoff_interval := (p_backoff_seconds * power(2, v_current_attempts - 1)) * interval '1 second';
    END IF;

    -- Update the job
    UPDATE jobs
    SET status       = v_new_status,
        lease_owner  = NULL,
        lease_until  = NULL,
        last_error   = p_error,
        available_at = CASE
                           WHEN v_new_status = 'retrying' THEN now() + v_backoff_interval
                           ELSE available_at
            END
    WHERE id = p_job_id;

    -- Return status as text (not enum) for easier Kotlin deserialization
    RETURN v_new_status::text;
END;
$$;

COMMENT ON FUNCTION fail_or_retry_job IS 'Fail or retry a job with exponential backoff. Raises JB001 if job not found.';
