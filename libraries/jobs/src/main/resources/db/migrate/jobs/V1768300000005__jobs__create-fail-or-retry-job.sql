SET SEARCH_PATH TO ${jobs}, public;

/**
 * Fail or retry a job.
 *
 * If the job has exhausted its retry attempts, marks it as 'failed'.
 * Otherwise, marks it as 'retrying' with exponential backoff.
 *
 * @param p_job_id - The job to fail/retry
 * @param p_worker_id - Optional: only update if this worker holds the lease
 * @param p_max_attempts - Maximum attempts before permanent failure (default: 3)
 * @param p_backoff_seconds - Base backoff duration in seconds (default: 30)
 * @param p_error - Error message to record
 * @returns The new job status
 */
CREATE OR REPLACE FUNCTION fail_or_retry_job(
    p_job_id uuid,
    p_worker_id text DEFAULT NULL,
    p_max_attempts int DEFAULT 3,
    p_backoff_seconds int DEFAULT 30,
    p_error text DEFAULT NULL
)
    RETURNS job_status
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
        RETURN NULL;
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

    RETURN v_new_status;
END;
$$;

COMMENT ON FUNCTION fail_or_retry_job IS 'Fail or retry a job with exponential backoff';
