SET SEARCH_PATH TO ${jobs}, public;

/**
 * Enqueue a job for async processing.
 *
 * If an idempotency key is provided and a job with that key already exists,
 * returns the existing job ID (deduplication).
 *
 * @param p_job_type - Type of job (e.g., 'run_planner', 'execute_plan')
 * @param p_target_type - What the job operates on (e.g., 'surface', 'plan')
 * @param p_target_id - UUID of the target entity
 * @param p_idempotency_key - Optional key for deduplication within job_type
 * @param p_params - Optional JSONB parameters for the job
 * @param p_priority - Priority (higher = more urgent, default 0)
 * @param p_available_at - When the job becomes available (default now)
 * @returns UUID of the job (new or existing)
 */
CREATE OR REPLACE FUNCTION enqueue_job(
    p_job_type text,
    p_target_type text,
    p_target_id uuid,
    p_idempotency_key text DEFAULT NULL,
    p_params jsonb DEFAULT NULL,
    p_priority int DEFAULT 0,
    p_available_at timestamptz DEFAULT now()
)
    RETURNS uuid
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_job_id uuid;
BEGIN
    -- If idempotency key provided, check for existing job first
    IF p_idempotency_key IS NOT NULL THEN
        SELECT id
        INTO v_job_id
        FROM jobs
        WHERE job_type = p_job_type
          AND idempotency_key = p_idempotency_key;

        IF FOUND THEN
            RETURN v_job_id;
        END IF;
    END IF;

    -- Insert new job
    INSERT INTO jobs (job_type,
                      target_type,
                      target_id,
                      idempotency_key,
                      params,
                      priority,
                      available_at)
    VALUES (p_job_type,
            p_target_type,
            p_target_id,
            p_idempotency_key,
            p_params,
            p_priority,
            p_available_at)
    ON CONFLICT (job_type, idempotency_key) DO NOTHING
    RETURNING id INTO v_job_id;

    -- If insert was skipped due to race condition, fetch existing
    IF v_job_id IS NULL AND p_idempotency_key IS NOT NULL THEN
        SELECT id
        INTO v_job_id
        FROM jobs
        WHERE job_type = p_job_type
          AND idempotency_key = p_idempotency_key;
    END IF;

    RETURN v_job_id;
END;
$$;

COMMENT ON FUNCTION enqueue_job IS 'Enqueue a job with optional idempotency key for deduplication';
