SET SEARCH_PATH TO ${jobs}, public;

/**
 * Notification trigger for job queue wake-ups.
 *
 * When a job becomes ready (pending/retrying with available_at <= now),
 * notify the job_notifications channel so workers can wake up.
 */

CREATE OR REPLACE FUNCTION notify_on_ready_job()
    RETURNS TRIGGER
    LANGUAGE plpgsql
AS
$$
BEGIN
    -- Only notify if the job is ready to be processed
    IF NEW.status IN ('pending', 'retrying') AND NEW.available_at <= now() THEN
        PERFORM pg_notify('job_notifications', '');
    END IF;
    RETURN NEW;
END;
$$;

-- Trigger on INSERT or UPDATE of status/available_at
DROP TRIGGER IF EXISTS trg_notify_on_ready_job ON jobs;
CREATE TRIGGER trg_notify_on_ready_job
    AFTER INSERT OR UPDATE OF status, available_at
    ON jobs
    FOR EACH ROW
EXECUTE FUNCTION notify_on_ready_job();

COMMENT ON FUNCTION notify_on_ready_job IS 'Notifies job_notifications channel when a job becomes ready';
