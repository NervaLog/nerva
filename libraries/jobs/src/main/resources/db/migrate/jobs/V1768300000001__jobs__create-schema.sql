/**
 * Jobs schema - Background job queue for async processing.
 *
 * Unlike the events schema (which stores external events), this schema
 * is for internal background jobs like running the planner and executor.
 *
 * External events (Stripe webhooks, etc.) now go to the ledger journal as facts.
 * This queue is for the async work that results from those facts.
 */

CREATE SCHEMA IF NOT EXISTS ${jobs};
SET SEARCH_PATH TO ${jobs}, public;

-- Job status enum
CREATE TYPE job_status AS ENUM (
    'pending', -- Waiting to be picked up
    'processing', -- Currently leased by a worker
    'retrying', -- Failed once, will retry after available_at
    'completed', -- Successfully processed (terminal)
    'failed', -- Retry attempts exhausted (terminal)
    'dead' -- Manually marked as unprocessable (terminal)
    );

-- Main jobs table
CREATE TABLE jobs
(
    id              uuid PRIMARY KEY     DEFAULT gen_random_uuid(),

    -- Job identification
    job_type        text        NOT NULL,           -- 'run_planner', 'execute_plan', 'sync_surface'
    idempotency_key text,                           -- Optional: for deduplication

    -- Target (what the job operates on)
    target_type     text        NOT NULL,           -- 'surface', 'plan'
    target_id       uuid        NOT NULL,

    -- Job parameters (type-specific)
    params          jsonb,

    -- Scheduling
    priority        int         NOT NULL DEFAULT 0, -- Higher = more urgent
    created_at      timestamptz NOT NULL DEFAULT now(),
    available_at    timestamptz NOT NULL DEFAULT now(),

    -- Processing state
    status          job_status  NOT NULL DEFAULT 'pending',
    lease_owner     text,                           -- Worker ID holding the lease
    lease_until     timestamptz,                    -- When the lease expires
    attempts        int         NOT NULL DEFAULT 0,
    last_error      text,
    completed_at    timestamptz,

    -- Idempotency constraint: same job_type + idempotency_key = same job
    CONSTRAINT jobs_idempotency_unique UNIQUE (job_type, idempotency_key)
);

-- Ready queue index: jobs that can be picked up, ordered by priority then time
CREATE INDEX jobs_ready_idx
    ON jobs (priority DESC, available_at, id)
    WHERE status IN ('pending', 'retrying');

-- Target lookup: find jobs for a specific target
CREATE INDEX jobs_target_idx
    ON jobs (target_type, target_id, created_at DESC);

-- Expired lease recovery: find jobs with expired leases
CREATE INDEX jobs_expired_lease_idx
    ON jobs (lease_until)
    WHERE status = 'processing' AND lease_until IS NOT NULL;

-- Job type index for filtering
CREATE INDEX jobs_type_idx ON jobs (job_type);

-- Dead letter queue (copy of jobs table structure)
CREATE TABLE jobs_dead_letter
(
    LIKE jobs INCLUDING ALL
);

COMMENT ON TABLE jobs IS 'Background job queue for async processing (planner, executor, etc.)';
COMMENT ON TABLE jobs_dead_letter IS 'Dead letter queue for failed jobs that need manual review';
COMMENT ON COLUMN jobs.job_type IS 'Type of job: run_planner, execute_plan, sync_surface';
COMMENT ON COLUMN jobs.idempotency_key IS 'Optional key for deduplication within job_type';
COMMENT ON COLUMN jobs.target_type IS 'What the job operates on: surface, plan';
COMMENT ON COLUMN jobs.target_id IS 'UUID of the target entity';
COMMENT ON COLUMN jobs.priority IS 'Higher values = higher priority';
