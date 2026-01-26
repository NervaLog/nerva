SET SEARCH_PATH TO ${jobs}, public;

/**
 * Mark a job as completed.
 *
 * @param p_job_id - The job to complete
 * @param p_worker_id - Optional: only complete if this worker holds the lease
 * @returns true if the job was completed, false otherwise
 */
CREATE OR REPLACE FUNCTION complete_job(
    p_job_id uuid,
    p_worker_id text DEFAULT NULL
)
    RETURNS boolean
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_updated int;
BEGIN
    UPDATE jobs
    SET status       = 'completed',
        lease_owner  = NULL,
        lease_until  = NULL,
        last_error   = NULL,
        completed_at = now()
    WHERE id = p_job_id
      AND status = 'processing'
      AND (p_worker_id IS NULL OR lease_owner = p_worker_id);

    GET DIAGNOSTICS v_updated = ROW_COUNT;
    RETURN v_updated > 0;
END;
$$;

COMMENT ON FUNCTION complete_job IS 'Mark a job as successfully completed';
