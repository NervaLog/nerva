SET SEARCH_PATH TO ${jobs}, public;

/**
 * Queue statistics for metrics/monitoring.
 *
 * Returns counts and oldest job age by status for gauge metrics.
 */
CREATE OR REPLACE FUNCTION queue_stats()
    RETURNS TABLE
            (
                status             text,
                count              bigint,
                oldest_age_seconds double precision
            )
    LANGUAGE sql
    STABLE
AS
$$
SELECT s.status::text,
       COALESCE(q.count, 0)              as count,
       COALESCE(q.oldest_age_seconds, 0) as oldest_age_seconds
FROM (
         -- All possible statuses we care about
         VALUES ('pending'), ('processing'), ('retrying'), ('failed')) AS s(status)
         LEFT JOIN (SELECT j.status::text                                  as status,
                           COUNT(*)                                        as count,
                           EXTRACT(EPOCH FROM (now() - MIN(j.created_at))) as oldest_age_seconds
                    FROM jobs j
                    WHERE j.status IN ('pending', 'processing', 'retrying', 'failed')
                    GROUP BY j.status) q ON s.status = q.status;
$$;

COMMENT ON FUNCTION queue_stats IS 'Get queue depth and oldest job age by status for metrics gauges';
