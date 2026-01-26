package dev.dailywombat.jobs.runtime

import io.micrometer.core.instrument.Counter
import io.micrometer.core.instrument.Gauge
import io.micrometer.core.instrument.MeterRegistry
import io.micrometer.core.instrument.Timer
import io.micrometer.core.instrument.simple.SimpleMeterRegistry
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicReference

/**
 * Metrics for the jobs system.
 *
 * All counters are tagged by job_type for per-type breakdown.
 * Gauges track queue depth and staleness.
 *
 * ## Configuration
 *
 * By default uses SimpleMeterRegistry. For production, configure with your
 * preferred registry (Prometheus, Datadog, etc.):
 *
 * ```kotlin
 * JobMetrics.configure(PrometheusMeterRegistry(PrometheusConfig.DEFAULT))
 * ```
 *
 * ## Metrics
 *
 * **Counters** (tagged by job_type):
 * - `jobs.leased` - Jobs leased for processing
 * - `jobs.completed` - Jobs completed successfully
 * - `jobs.retried` - Jobs scheduled for retry
 * - `jobs.failed` - Jobs that exhausted retries
 * - `jobs.replayed` - Jobs replayed from DLQ
 *
 * **Counters** (no tags):
 * - `jobs.recovered` - Stale jobs recovered
 *
 * **Timers** (tagged by job_type):
 * - `jobs.processing.duration` - Job execution time (p50/p95/p99)
 *
 * **Gauges** (tagged by status):
 * - `jobs.queue.depth` - Current queue size by status
 * - `jobs.queue.oldest_age_seconds` - Age of oldest job by status
 */
object JobMetrics {

    private var _registry: MeterRegistry = SimpleMeterRegistry()
    val registry: MeterRegistry get() = _registry

    // Cache for tagged counters/timers to avoid re-creating on every call
    private val leasedCounters = ConcurrentHashMap<String, Counter>()
    private val completedCounters = ConcurrentHashMap<String, Counter>()
    private val retriedCounters = ConcurrentHashMap<String, Counter>()
    private val failedCounters = ConcurrentHashMap<String, Counter>()
    private val replayedCounters = ConcurrentHashMap<String, Counter>()
    private val processingTimers = ConcurrentHashMap<String, Timer>()

    // Queue stats holders for gauges (updated by QueueStatsPoller)
    private val queueDepth = ConcurrentHashMap<String, AtomicReference<Double>>()
    private val queueOldestAge = ConcurrentHashMap<String, AtomicReference<Double>>()

    // Untagged counter for recovered jobs
    private lateinit var _recoveredCounter: Counter

    init {
        rebind()
    }

    /**
     * Configure the metrics registry.
     *
     * Call this at application startup before processing jobs.
     * After calling, all existing metrics will be re-registered with the new registry.
     */
    fun configure(registry: MeterRegistry) {
        _registry = registry
        leasedCounters.clear()
        completedCounters.clear()
        retriedCounters.clear()
        failedCounters.clear()
        replayedCounters.clear()
        processingTimers.clear()
        rebind()
    }

    private fun rebind() {
        _recoveredCounter = Counter.builder("jobs.recovered")
            .description("Total number of stale jobs recovered")
            .register(_registry)

        // Pre-register gauge holders for known statuses
        listOf("pending", "processing", "retrying", "failed").forEach { status ->
            queueDepth.computeIfAbsent(status) { AtomicReference(0.0) }
            queueOldestAge.computeIfAbsent(status) { AtomicReference(0.0) }

            Gauge.builder("jobs.queue.depth") { queueDepth[status]?.get() ?: 0.0 }
                .description("Current number of jobs in queue by status")
                .tag("status", status)
                .register(_registry)

            Gauge.builder("jobs.queue.oldest_age_seconds") { queueOldestAge[status]?.get() ?: 0.0 }
                .description("Age of oldest job in seconds by status")
                .tag("status", status)
                .register(_registry)
        }
    }

    // =========================================================================
    // Tagged Counters
    // =========================================================================

    /** Increment jobs.leased counter for the given job type */
    fun leased(jobType: String): Counter = leasedCounters.computeIfAbsent(jobType) {
        Counter.builder("jobs.leased")
            .description("Total number of jobs leased for processing")
            .tag("job_type", jobType)
            .register(_registry)
    }

    /** Increment jobs.completed counter for the given job type */
    fun completed(jobType: String): Counter = completedCounters.computeIfAbsent(jobType) {
        Counter.builder("jobs.completed")
            .description("Total number of jobs completed successfully")
            .tag("job_type", jobType)
            .register(_registry)
    }

    /** Increment jobs.retried counter for the given job type */
    fun retried(jobType: String): Counter = retriedCounters.computeIfAbsent(jobType) {
        Counter.builder("jobs.retried")
            .description("Total number of jobs marked for retry")
            .tag("job_type", jobType)
            .register(_registry)
    }

    /** Increment jobs.failed counter for the given job type */
    fun failed(jobType: String): Counter = failedCounters.computeIfAbsent(jobType) {
        Counter.builder("jobs.failed")
            .description("Total number of jobs that exhausted retries")
            .tag("job_type", jobType)
            .register(_registry)
    }

    /** Increment jobs.replayed counter for the given job type */
    fun replayed(jobType: String): Counter = replayedCounters.computeIfAbsent(jobType) {
        Counter.builder("jobs.replayed")
            .description("Total number of jobs replayed from DLQ")
            .tag("job_type", jobType)
            .register(_registry)
    }

    // =========================================================================
    // Untagged Counters
    // =========================================================================

    /** Counter for stale jobs recovered (no job_type since we don't know it at recovery time) */
    val recovered: Counter get() = _recoveredCounter

    // =========================================================================
    // Timers
    // =========================================================================

    /** Timer for job processing duration by job type */
    fun processingDuration(jobType: String): Timer = processingTimers.computeIfAbsent(jobType) {
        Timer.builder("jobs.processing.duration")
            .description("Job execution duration")
            .tag("job_type", jobType)
            .publishPercentiles(0.5, 0.95, 0.99)
            .register(_registry)
    }

    // =========================================================================
    // Gauge Updates (called by QueueStatsPoller)
    // =========================================================================

    /**
     * Update queue depth gauge for a status.
     * Called by QueueStatsPoller.
     */
    fun updateQueueDepth(status: String, count: Double) {
        queueDepth.computeIfAbsent(status) { AtomicReference(0.0) }.set(count)
    }

    /**
     * Update oldest job age gauge for a status.
     * Called by QueueStatsPoller.
     */
    fun updateOldestAge(status: String, ageSeconds: Double) {
        queueOldestAge.computeIfAbsent(status) { AtomicReference(0.0) }.set(ageSeconds)
    }

    // =========================================================================
    // Legacy API (deprecated, for backward compatibility)
    // =========================================================================

    @Deprecated("Use leased(jobType) instead", ReplaceWith("leased(jobType)"))
    val jobs_leased: Counter
        get() = Counter.builder("jobs.leased.total")
            .description("Total jobs leased (deprecated, use tagged version)")
            .register(_registry)

    @Deprecated("Use completed(jobType) instead", ReplaceWith("completed(jobType)"))
    val jobs_completed: Counter
        get() = Counter.builder("jobs.completed.total")
            .description("Total jobs completed (deprecated, use tagged version)")
            .register(_registry)

    @Deprecated("Use retried(jobType) instead", ReplaceWith("retried(jobType)"))
    val jobs_retried: Counter
        get() = Counter.builder("jobs.retried.total")
            .description("Total jobs retried (deprecated, use tagged version)")
            .register(_registry)

    @Deprecated("Use failed(jobType) instead", ReplaceWith("failed(jobType)"))
    val jobs_failed: Counter
        get() = Counter.builder("jobs.failed.total")
            .description("Total jobs failed (deprecated, use tagged version)")
            .register(_registry)

    @Deprecated("Use recovered instead", ReplaceWith("recovered"))
    val jobs_recovered: Counter get() = _recoveredCounter
}
