package dev.dailywombat.jobs.integration.support.db

import dev.dailywombat.PostgresContainer
import dev.dailywombat.jobs.integration.support.JobsIntegrationEnv
import java.sql.Connection
import java.sql.DriverManager
import java.sql.ResultSet
import java.sql.Timestamp
import java.time.Instant
import java.util.*

/**
 * Direct database access for integration test assertions.
 *
 * Uses JDBC to bypass PostgREST for verification and setup operations.
 */
object JobsDb {

    /**
     * Open a new database connection.
     * Caller is responsible for closing.
     */
    fun openConnection(): Connection = DriverManager.getConnection(
        JobsIntegrationEnv.standardJdbcUrl,
        PostgresContainer.Username,
        PostgresContainer.Password
    )

    /**
     * Execute a block with a connection that is automatically closed.
     */
    inline fun <T> withConnection(block: (Connection) -> T): T {
        return openConnection().use(block)
    }

    /**
     * Fetch a single job by ID.
     */
    fun fetchJob(conn: Connection, id: UUID): JobRow? {
        val sql = """
            SELECT id, job_type, idempotency_key, target_type, target_id,
                   priority, params, created_at, available_at, status,
                   lease_owner, lease_until, lease_count, attempts,
                   last_error, completed_at, replayed_from
            FROM jobs.jobs
            WHERE id = ?
        """.trimIndent()

        return conn.prepareStatement(sql).use { stmt ->
            stmt.setObject(1, id)
            stmt.executeQuery().use { rs ->
                if (rs.next()) rs.toJobRow() else null
            }
        }
    }

    /**
     * Fetch all jobs, ordered by created_at desc.
     */
    fun fetchAllJobs(conn: Connection, limit: Int = 100): List<JobRow> {
        val sql = """
            SELECT id, job_type, idempotency_key, target_type, target_id,
                   priority, params, created_at, available_at, status,
                   lease_owner, lease_until, lease_count, attempts,
                   last_error, completed_at, replayed_from
            FROM jobs.jobs
            ORDER BY created_at DESC
            LIMIT ?
        """.trimIndent()

        return conn.prepareStatement(sql).use { stmt ->
            stmt.setInt(1, limit)
            stmt.executeQuery().use { rs ->
                generateSequence { if (rs.next()) rs.toJobRow() else null }.toList()
            }
        }
    }

    /**
     * Count jobs by status.
     */
    fun countByStatus(conn: Connection): Map<String, Int> {
        val sql = "SELECT status::text, COUNT(*) FROM jobs.jobs GROUP BY status"

        return conn.prepareStatement(sql).use { stmt ->
            stmt.executeQuery().use { rs ->
                generateSequence {
                    if (rs.next()) rs.getString(1) to rs.getInt(2) else null
                }.toMap()
            }
        }
    }

    /**
     * Count jobs with a specific job type and idempotency key.
     */
    fun countJobsWithIdempotencyKey(conn: Connection, jobType: String, idempotencyKey: String): Int {
        val sql = """
            SELECT COUNT(*) FROM jobs.jobs
            WHERE job_type = ? AND idempotency_key = ?
        """.trimIndent()

        return conn.prepareStatement(sql).use { stmt ->
            stmt.setString(1, jobType)
            stmt.setString(2, idempotencyKey)
            stmt.executeQuery().use { rs ->
                rs.next()
                rs.getInt(1)
            }
        }
    }

    /**
     * Truncate all job tables.
     */
    fun truncateJobs(conn: Connection) {
        conn.createStatement().use { stmt ->
            stmt.execute("TRUNCATE jobs.jobs CASCADE")
        }
    }

    /**
     * Get current database time.
     */
    fun now(conn: Connection): Instant {
        return conn.prepareStatement("SELECT now()").use { stmt ->
            stmt.executeQuery().use { rs ->
                rs.next()
                rs.getTimestamp(1).toInstant()
            }
        }
    }

    /**
     * Manually set available_at for testing backoff.
     */
    fun setAvailableAt(conn: Connection, id: UUID, time: Instant) {
        conn.prepareStatement("UPDATE jobs.jobs SET available_at = ? WHERE id = ?").use { stmt ->
            stmt.setTimestamp(1, Timestamp.from(time))
            stmt.setObject(2, id)
            stmt.executeUpdate()
        }
    }

    /**
     * Manually expire a lease for testing stale recovery.
     */
    fun expireLease(conn: Connection, id: UUID) {
        conn.prepareStatement(
            "UPDATE jobs.jobs SET lease_until = now() - interval '1 hour' WHERE id = ?"
        ).use { stmt ->
            stmt.setObject(1, id)
            stmt.executeUpdate()
        }
    }

    /**
     * Force a job into a specific status for testing.
     */
    fun setJobStatus(conn: Connection, id: UUID, status: String) {
        conn.prepareStatement("UPDATE jobs.jobs SET status = ?::jobs.job_status WHERE id = ?").use { stmt ->
            stmt.setString(1, status)
            stmt.setObject(2, id)
            stmt.executeUpdate()
        }
    }

    private fun ResultSet.toJobRow() = JobRow(
        id = getObject("id", UUID::class.java),
        jobType = getString("job_type"),
        idempotencyKey = getString("idempotency_key"),
        targetType = getString("target_type"),
        targetId = getObject("target_id", UUID::class.java),
        priority = getInt("priority"),
        params = getString("params"),
        createdAt = getTimestamp("created_at")?.toInstant(),
        availableAt = getTimestamp("available_at")?.toInstant(),
        status = getString("status"),
        leaseOwner = getString("lease_owner"),
        leaseUntil = getTimestamp("lease_until")?.toInstant(),
        leaseCount = getInt("lease_count"),
        attempts = getInt("attempts"),
        lastError = getString("last_error"),
        completedAt = getTimestamp("completed_at")?.toInstant(),
        replayedFrom = getObject("replayed_from", UUID::class.java)
    )
}

