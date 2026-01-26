SET SEARCH_PATH TO ${jobs}, public;

/**
 * DLQ (Dead Letter Queue) tooling for failed jobs.
 *
 * Provides:
 * - list_failed_jobs: Query failed jobs with filters
 * - replay_job: Create new job from failed one (preserves audit trail)
 */

-- Add replayed_from column to track job lineage
ALTER TABLE jobs
    ADD COLUMN IF NOT EXISTS replayed_from uuid REFERENCES jobs (id);

COMMENT ON COLUMN jobs.replayed_from IS 'If this job was replayed from a failed job, references the original';

-- Index for finding replays of a job
CREATE INDEX IF NOT EXISTS jobs_replayed_from_idx ON jobs (replayed_from) WHERE replayed_from IS NOT NULL;

/**
 * List failed jobs with optional filters.
 *
 * @param p_job_type Filter by job type (NULL = all)
 * @param p_target_type Filter by target type (NULL = all)
 * @param p_since Only jobs created after this time (NULL = no lower bound)
 * @param p_until Only jobs created before this time (NULL = no upper bound)
 * @param p_error_like Filter by error message pattern (NULL = all)
 * @param p_limit Max results (default 50)
 * @param p_offset Skip first N results (default 0)
 */
CREATE OR REPLACE FUNCTION list_failed_jobs(
    p_job_type text DEFAULT NULL,
    p_target_type text DEFAULT NULL,
    p_since timestamptz DEFAULT NULL,
    p_until timestamptz DEFAULT NULL,
    p_error_like text DEFAULT NULL,
    p_limit int DEFAULT 50,
    p_offset int DEFAULT 0
)
    RETURNS TABLE
            (
                id            uuid,
                job_type      text,
                target_type   text,
                target_id     uuid,
                created_at    timestamptz,
                completed_at  timestamptz,
                attempts      int,
                lease_count   int,
                last_error    text,
                replayed_from uuid
            )
    LANGUAGE sql
    STABLE
AS
$$
SELECT j.id,
       j.job_type,
       j.target_type,
       j.target_id,
       j.created_at,
       j.completed_at,
       j.attempts,
       j.lease_count,
       LEFT(j.last_error, 500) as last_error, -- truncate for list view
       j.replayed_from
FROM jobs j
WHERE j.status = 'failed'
  AND (p_job_type IS NULL OR j.job_type = p_job_type)
  AND (p_target_type IS NULL OR j.target_type = p_target_type)
  AND (p_since IS NULL OR j.created_at >= p_since)
  AND (p_until IS NULL OR j.created_at <= p_until)
  AND (p_error_like IS NULL OR j.last_error ILIKE '%' || p_error_like || '%')
ORDER BY j.completed_at DESC NULLS LAST, j.created_at DESC
LIMIT p_limit OFFSET p_offset;
$$;

COMMENT ON FUNCTION list_failed_jobs IS 'List failed jobs with optional filters for DLQ inspection';

/**
 * Get full details of a job (any status).
 *
 * @param p_job_id The job ID to inspect
 * @returns Full job record as JSONB, or NULL if not found
 */
CREATE OR REPLACE FUNCTION inspect_job(p_job_id uuid)
    RETURNS jsonb
    LANGUAGE sql
    STABLE
AS
$$
SELECT to_jsonb(j.*)
FROM jobs j
WHERE j.id = p_job_id;
$$;

COMMENT ON FUNCTION inspect_job IS 'Get full details of a job including params and complete error';

/**
 * Replay a failed job by creating a new job with the same parameters.
 *
 * The original job stays in 'failed' status for audit trail.
 * The new job references the original via replayed_from.
 *
 * @param p_job_id The failed job to replay
 * @returns The new job's ID
 * @raises JB002 if job not found
 * @raises JB003 if job is not in failed status
 */
CREATE OR REPLACE FUNCTION replay_job(p_job_id uuid)
    RETURNS uuid
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_original jobs%ROWTYPE;
    v_new_id   uuid;
BEGIN
    -- Get the original job
    SELECT *
    INTO v_original
    FROM jobs
    WHERE id = p_job_id;

    IF v_original IS NULL THEN
        RAISE EXCEPTION 'job_not_found'
            USING ERRCODE = 'JB002';
    END IF;

    IF v_original.status != 'failed' THEN
        RAISE EXCEPTION 'job_not_failed'
            USING ERRCODE = 'JB003';
    END IF;

    -- Create new job from original
    INSERT INTO jobs (job_type,
                      target_type,
                      target_id,
                      params,
                      priority,
                      replayed_from)
    VALUES (v_original.job_type,
            v_original.target_type,
            v_original.target_id,
            v_original.params,
            v_original.priority,
            v_original.id -- link back to original
           )
    RETURNING id INTO v_new_id;

    RETURN v_new_id;
END;
$$;

COMMENT ON FUNCTION replay_job IS 'Create new job from failed job. Original preserved for audit. Raises JB002 if not found, JB003 if not failed.';
