SET SEARCH_PATH TO ${jobs}, public;

/**
 * Fix enqueue_job function to use proper search path.
 *
 * The function needs SET search_path in its definition so that
 * when called from other schemas, it can still find the jobs table.
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
    SET search_path = ${jobs}, public
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
