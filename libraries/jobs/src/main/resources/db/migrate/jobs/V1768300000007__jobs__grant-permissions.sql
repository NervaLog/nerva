SET SEARCH_PATH TO ${jobs}, public;

/**
 * Grant permissions for PostgREST access.
 */

-- Schema access
GRANT USAGE ON SCHEMA ${jobs} TO web_anon;

-- Table access
GRANT SELECT, INSERT, UPDATE ON jobs TO web_anon;
GRANT SELECT, INSERT ON jobs_dead_letter TO web_anon;

-- Function access
GRANT EXECUTE ON FUNCTION lease_jobs TO web_anon;
GRANT EXECUTE ON FUNCTION complete_job TO web_anon;
GRANT EXECUTE ON FUNCTION fail_or_retry_job TO web_anon;
GRANT EXECUTE ON FUNCTION move_to_dead_letter TO web_anon;
GRANT EXECUTE ON FUNCTION find_stale_jobs TO web_anon;
GRANT EXECUTE ON FUNCTION release_stale_job TO web_anon;
