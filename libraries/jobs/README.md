# Jobs Library

A PostgreSQL-backed background job queue for async processing. Unlike the events library (which handled external
webhooks), this library is for **internal background work** like running the planner, executor, and surface sync
operations.

---

## Quick Navigation

- [Why a Job Queue?](#why-a-job-queue)
- [Architecture](#architecture)
- [Core Concepts](#core-concepts)
- [Database Schema](#database-schema)
- [Actions API](#actions-api)
- [Dead Letter Queue (DLQ)](#dead-letter-queue-dlq)
- [Metrics](#metrics)
- [Job Handlers](#job-handlers)
- [LISTEN/NOTIFY Wake-ups](#listennotify-wake-ups)
- [Usage Examples](#usage-examples)
- [Testing](#testing)

---

## Why a Job Queue?

When a Stripe webhook arrives, we don't want to block the HTTP response while we:

1. Run the planner to compute entitlement diffs
2. Execute actions against Discord/email/etc.
3. Handle retries on failure

Instead, we:

1. Record the fact in the Ledger journal (fast, synchronous)
2. Enqueue a job to process it (fast, synchronous)
3. Return 200 OK to Stripe
4. Process the job asynchronously with retries

```
Webhook → Record Fact → Enqueue Job → Return 200
                              ↓
                        (async worker)
                              ↓
                     Planner → Executor → Discord
```

---

## Architecture

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│   Job Producer  │────▶│  PostgreSQL      │────▶│   Job Worker    │
│  (EnqueueJob)   │     │  jobs.jobs table │     │  (LeaseJobs)    │
└─────────────────┘     └──────────────────┘     └─────────────────┘
                               │
                               │ NOTIFY job_notifications
                               ▼
                        ┌──────────────────┐
                        │  WakeUpGate      │
                        │  (LISTEN)        │
                        └──────────────────┘
```

**Key design decisions:**

- **PostgreSQL as queue** - No separate Redis/RabbitMQ dependency
- **SKIP LOCKED leasing** - Multiple workers can run concurrently without conflicts
- **Idempotency keys** - Same job won't be enqueued twice
- **LISTEN/NOTIFY** - Workers wake up immediately when jobs arrive (no polling delay)

---

## Core Concepts

### Jobs

A job represents a unit of async work:

| Field             | Description                                             |
|-------------------|---------------------------------------------------------|
| `job_type`        | What kind of work (e.g., `run_planner`, `execute_plan`) |
| `target_type`     | What entity type it operates on (`surface`, `plan`)     |
| `target_id`       | UUID of the target entity                               |
| `idempotency_key` | Optional key for deduplication                          |
| `params`          | JSONB payload for job-specific data                     |
| `priority`        | Higher = more urgent (default 0)                        |
| `available_at`    | When the job becomes available                          |

### Job Lifecycle

```
pending → processing → completed
              ↓
          retrying → processing → completed
              ↓
            failed → (dead letter)
```

| Status       | Description                              |
|--------------|------------------------------------------|
| `pending`    | Waiting to be picked up                  |
| `processing` | Leased by a worker                       |
| `retrying`   | Failed, will retry after backoff         |
| `completed`  | Successfully finished (terminal)         |
| `failed`     | Exhausted retries (terminal)             |
| `dead`       | Manually marked unprocessable (terminal) |

### Leasing

Workers **lease** jobs rather than claiming them permanently:

- Lease has a duration (default 2 minutes)
- If worker crashes, lease expires and job returns to queue
- Uses `FOR UPDATE SKIP LOCKED` for concurrent-safe claiming

### Lease Count vs Attempts

The system distinguishes between **leases** and **execution failures**:

| Field         | Incremented When          | Purpose                                            |
|---------------|---------------------------|----------------------------------------------------|
| `lease_count` | Job is leased by a worker | Observability — how many times was this picked up? |
| `attempts`    | Execution actually fails  | Retry budget — how many real failures?             |

**Why this matters:** If a worker crashes mid-processing (stale lease), the job returns to the queue without burning a
retry attempt. Only actual execution failures count against the retry budget.

```
Worker A leases job    → lease_count=1, attempts=0
Worker A crashes       → stale recovery releases job
Worker B leases job    → lease_count=2, attempts=0  (no retry burned!)
Worker B runs, fails   → lease_count=2, attempts=1  (real failure)
Worker C leases job    → lease_count=3, attempts=1
Worker C succeeds      → completed
```

### Stale Job Recovery

Jobs stuck in `processing` with expired leases are recovered automatically:

```kotlin
val recovery = StaleJobRecovery(
    postgRestClient = pgRest,
    interval = 30.seconds,  // check every 30s
    limit = 100             // recover up to 100 per run
)
recovery.start()
```

Stale jobs are released back to `retrying` status without incrementing `attempts`.

---

## Database Schema

### Tables

| Table              | Purpose                       |
|--------------------|-------------------------------|
| `jobs`             | Main job queue                |
| `jobs_dead_letter` | Failed jobs for manual review |

### Jobs Table

```sql
CREATE TABLE jobs.jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    job_type text NOT NULL,
    idempotency_key text,
    target_type text NOT NULL,
    target_id uuid NOT NULL,
    params jsonb,
    priority int NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    available_at timestamptz NOT NULL DEFAULT now(),
    status job_status NOT NULL DEFAULT 'pending',
    lease_owner text,
    lease_until timestamptz,
    lease_count int NOT NULL DEFAULT 0,  -- times leased (observability)
    attempts int NOT NULL DEFAULT 0,      -- actual failures (retry budget)
    last_error text,
    completed_at timestamptz,
    replayed_from uuid REFERENCES jobs(id),  -- DLQ: links to original failed job
    CONSTRAINT jobs_idempotency_unique UNIQUE (job_type, idempotency_key)
);
```

### Key Indexes

- `jobs_ready_idx` - Jobs ready to process, ordered by priority
- `jobs_target_idx` - Find jobs for a specific target
- `jobs_expired_lease_idx` - Recover jobs with expired leases

### Stored Procedures

| Procedure              | Purpose                                                         |
|------------------------|-----------------------------------------------------------------|
| `enqueue_job()`        | Insert job with idempotency handling                            |
| `lease_jobs()`         | Atomically claim jobs for processing (increments `lease_count`) |
| `complete_job()`       | Mark job as successfully completed                              |
| `fail_or_retry_job()`  | Fail or schedule retry with backoff (increments `attempts`)     |
| `release_stale_jobs()` | Recover jobs with expired leases                                |
| `list_failed_jobs()`   | Query failed jobs with filters (DLQ)                            |
| `inspect_job()`        | Get full job details including params (DLQ)                     |
| `replay_job()`         | Create new job from failed one (DLQ)                            |
| `queue_stats()`        | Get queue depth and oldest age by status (Metrics)              |

---

## Actions API

### EnqueueJob

Enqueue a job with optional idempotency.

```kotlin
context(pgRest: PostgRestClient, _: Raise<PostgRestError>) {
    val jobId = EnqueueJob(
        EnqueueJobInput(
            jobType = "run_planner",
            targetType = "surface",
            targetId = surfaceId,
            idempotencyKey = "planner_${surfaceId}_${sequenceNum}",
            params = mapOf("cursor" to 42),
            priority = 10
        )
    )
}
```

**Idempotency**: If a job with the same `(job_type, idempotency_key)` exists, returns the existing job ID.

### Type-Safe Enqueueing (Recommended)

Instead of stringly-typed job names (which can have typos), use the Job object directly with extension functions from
`jobs-runtime`:

```kotlin
import dev.dailywombat.jobs.runtime.actions.enqueue

context(pgRest: PostgRestClient, _: Raise<PostgRestError>) {
    // Type-safe: can't misspell job type, params are type-checked
    val jobId = RunPlannerJob.enqueue(
        targetType = "surface",
        targetId = surfaceId,
        params = RunPlannerJob.Params(cursor = 42),  // compile-time checked!
        idempotencyKey = "planner_${surfaceId}_${sequenceNum}",
        priority = 10
    )
}
```

For jobs with no parameters (`UnitJob`):

```kotlin
context(pgRest: PostgRestClient, _: Raise<PostgRestError>) {
    val jobId = SyncDiscordRolesJob.enqueue(
        targetType = "surface",
        targetId = surfaceId
    )
}
```

**Benefits**:

- **Compile-time safety**: Can't enqueue non-existent job types
- **Type-checked params**: Must match the Job's declared param type
- **IDE autocomplete**: For job types and their param classes

### LeaseJobs

Atomically claim jobs for processing.

```kotlin
context(pgRest: PostgRestClient, _: Raise<PostgRestError>) {
    val jobs: List<LeasedJob> = LeaseJobs(
        workerId = "worker-${hostname}-${pid}",
        limit = 10,
        leaseDurationMinutes = 2,
        jobTypes = listOf("run_planner", "execute_plan")  // optional filter
    )

    jobs.forEach { job ->
        println("Leased: ${job.id} type=${job.jobType} target=${job.targetId}")
    }
}
```

**LeasedJob** contains:

- `id`, `jobType`, `targetType`, `targetId`
- `params` (nullable JSONB map)
- `priority`
- `attempts` (actual execution failures)
- `leaseCount` (times leased, including this one)

### CompleteJob

Mark a job as successfully completed.

```kotlin
context(pgRest: PostgRestClient, _: Raise<PostgRestError>) {
    val success: Boolean = CompleteJob(
        jobId = job.id,
        workerId = "worker-123"  // optional: only complete if still leased by this worker
    )
}
```

### FailOrRetryJob

Fail or schedule retry with exponential backoff.

```kotlin
context(pgRest: PostgRestClient, _: Raise<PostgRestError>) {
    val result: FailOrRetryResult = FailOrRetryJob(
        jobId = job.id,
        workerId = "worker-123",
        maxAttempts = 3,
        backoffSeconds = 30,
        error = "Discord API returned 503"
    )

    when (result) {
        FailOrRetryResult.RETRYING -> println("Will retry after backoff")
        FailOrRetryResult.FAILED -> println("Exhausted retries, moved to failed")
        FailOrRetryResult.NOT_FOUND -> println("Job not found or not owned by worker")
    }
}
```

**Backoff**: Uses capped exponential backoff with jitter:

- Formula: `min(base * 2^attempts, maxBackoff) * jitter`
- Jitter: ±25% randomness to avoid thundering herd
- Default cap: 900 seconds (15 minutes)

| Attempt | Base (30s) | Capped | With Jitter |
|---------|------------|--------|-------------|
| 0       | 30s        | 30s    | 22-37s      |
| 1       | 60s        | 60s    | 45-75s      |
| 2       | 120s       | 120s   | 90-150s     |
| 3       | 240s       | 240s   | 180-300s    |
| 4       | 480s       | 480s   | 360-600s    |
| 5+      | 960s+      | 900s   | 675-1125s   |

---

## Dead Letter Queue (DLQ)

Jobs that exhaust their retry budget end up in `failed` status. The DLQ tooling lets you inspect and replay these jobs.

### Job Lineage

When a job is replayed, the original stays in `failed` status for audit trail. The new job has a `replayed_from` field
pointing back to the original:

```
Original job (failed) ←── replayed_from ── New job (pending)
```

This preserves complete history and lets you trace retry attempts.

### ListFailedJobs

Query failed jobs with optional filters.

```kotlin
context(pgRest: PostgRestClient, _: Raise<PostgRestError>) {
    val failed: List<FailedJob> = ListFailedJobs(
        jobType = "execute_plan",        // optional: filter by type
        targetType = "surface",          // optional: filter by target type
        since = Instant.now().minus(7, ChronoUnit.DAYS),  // optional: time range
        errorLike = "Discord",           // optional: search error messages (case-insensitive)
        limit = 50,                       // default 50
        offset = 0                        // for pagination
    )

    failed.forEach { job ->
        println("${job.id}: ${job.jobType} - ${job.lastError}")
    }
}
```

**FailedJob** contains:

- `id`, `jobType`, `targetType`, `targetId`
- `createdAt`, `completedAt` (when it failed)
- `attempts`, `leaseCount`
- `lastError` (truncated to 500 chars in list view)
- `replayedFrom` (if this job was itself a replay)

### InspectJob

Get full details of any job (works for any status, not just failed).

```kotlin
context(pgRest: PostgRestClient, _: Raise<PostgRestError>) {
    val details: JobDetails? = InspectJob(jobId)

    details?.let {
        println("Type: ${it.jobType}")
        println("Params: ${it.params}")
        println("Full error: ${it.lastError}")
        println("Attempts: ${it.attempts}, Leases: ${it.leaseCount}")
    }
}
```

**JobDetails** includes everything in `FailedJob` plus:

- `params` (full JSONB payload)
- `idempotencyKey`
- `priority`
- `status`, `leaseOwner`, `leaseUntil`
- `availableAt`

### ReplayJob

Create a new job from a failed one. The original is preserved for audit trail.

```kotlin
context(pgRest: PostgRestClient, _: Raise<PostgRestError>) {
    val result: ReplayResult = ReplayJob(failedJobId)

    when (result) {
        is ReplayResult.Success -> println("New job created: ${result.newJobId}")
        is ReplayResult.NotFound -> println("Job not found")
        is ReplayResult.NotFailed -> println("Job is not in failed status")
    }
}
```

The new job:

- Has the same `job_type`, `target_type`, `target_id`, `params`, `priority`
- Starts fresh with `attempts = 0`, `status = 'pending'`
- Has `replayed_from` pointing to the original job

### Example: DLQ Monitoring Script

```kotlin
// Find jobs that failed with Discord errors in the last 24 hours
val discordFailures = ListFailedJobs(
    errorLike = "Discord",
    since = Instant.now().minus(24, ChronoUnit.HOURS)
)

// Replay them all
discordFailures.forEach { job ->
    val result = ReplayJob(job.id)
    if (result is ReplayResult.Success) {
        println("Replayed ${job.id} → ${result.newJobId}")
    }
}
```

---

## Metrics

The jobs system exposes metrics via Micrometer for monitoring and alerting.

### Configuration

By default, metrics use a `SimpleMeterRegistry`. For production, configure with your preferred registry:

```kotlin
// At application startup
JobMetrics.configure(PrometheusMeterRegistry(PrometheusConfig.DEFAULT))

// Start the queue stats poller (updates gauge metrics)
val statsPoller = QueueStatsPoller(pgRest, interval = 15.seconds)
statsPoller.start()
```

### Available Metrics

**Counters** (tagged by `job_type`):

| Metric           | Description                 |
|------------------|-----------------------------|
| `jobs.leased`    | Jobs leased for processing  |
| `jobs.completed` | Jobs completed successfully |
| `jobs.retried`   | Jobs scheduled for retry    |
| `jobs.failed`    | Jobs that exhausted retries |
| `jobs.replayed`  | Jobs replayed from DLQ      |

**Counters** (untagged):

| Metric           | Description                          |
|------------------|--------------------------------------|
| `jobs.recovered` | Stale jobs recovered (lease expired) |

**Timers** (tagged by `job_type`):

| Metric                     | Description                      |
|----------------------------|----------------------------------|
| `jobs.processing.duration` | Job execution time (p50/p95/p99) |

**Gauges** (tagged by `status`):

| Metric                          | Description                                             |
|---------------------------------|---------------------------------------------------------|
| `jobs.queue.depth`              | Current queue size (pending/processing/retrying/failed) |
| `jobs.queue.oldest_age_seconds` | Age of oldest job by status                             |

### Queue Stats Poller

Gauges are updated by a background poller that queries the database periodically:

```kotlin
val statsPoller = QueueStatsPoller(
    postgRestClient = pgRest,
    interval = 15.seconds  // default
)
statsPoller.start()

// On shutdown
statsPoller.close()
```

This decouples Prometheus scrape frequency from database load.

### Example Prometheus Queries

```promql
# Job throughput by type (per minute)
rate(jobs_completed_total[1m])

# p99 processing latency
histogram_quantile(0.99, rate(jobs_processing_duration_seconds_bucket[5m]))

# Queue backlog
jobs_queue_depth{status="pending"}

# Failure rate
rate(jobs_failed_total[5m]) / rate(jobs_completed_total[5m])

# Oldest pending job (staleness alert)
jobs_queue_oldest_age_seconds{status="pending"} > 300
```

---

## Job Handlers

Jobs are processed by handler objects discovered at startup via classpath scanning.

### Defining a Handler

```kotlin
object RunPlannerJob : Job<RunPlannerParams>(
    type = "run_planner",
    paramsClass = RunPlannerParams::class
) {
    data class RunPlannerParams(val surfaceId: UUID, val cursor: Long?)

    override suspend fun invoke(params: RunPlannerParams): JobResult {
        // Do the work
        val result = Planner.planForSurface(params.surfaceId)

        return when (result) {
            is PlanResult.Created -> JobResult.Success
            is PlanResult.NothingToDo -> JobResult.Success
            else -> JobResult.Failure("Unexpected result: $result")
        }
    }
}
```

### Job Base Class

```kotlin
abstract class Job<A : Any>(
    val type: String,
    private val paramsClass: KClass<A>
) {
    abstract suspend operator fun invoke(params: A): JobResult
}

// For jobs with no params
abstract class UnitJob(type: String) : Job<Unit>(type, Unit::class)
```

### JobResult

```kotlin
sealed interface JobResult {
    data object Success : JobResult
    data class Failure(val error: String, val retryable: Boolean = true) : JobResult
}
```

### JobRegistry

Jobs are auto-discovered from classpath via ClassGraph scanning. Any Kotlin `object` that extends `Job<A>` or `UnitJob`
is automatically registered.

```kotlin
// At startup - validates no duplicates and logs discovered handlers
JobRegistry.logDiscovered(logger)

// Lookup handler by type string
val handler: Job<*>? = JobRegistry["run_planner"]

// All registered types
val types: Set<String> = JobRegistry.types
```

**Duplicate Detection**: If two Job objects declare the same `type` string, the registry throws
`DuplicateJobTypeException` at startup:

```kotlin
// This will fail at startup:
object RunPlannerJob : Job<Params>("run_planner", ...) { ... }
object AnotherPlanner : Job<OtherParams>("run_planner", ...) { ... }  // Same type!

// Error:
// DuplicateJobTypeException: Duplicate job type 'run_planner' declared by
// multiple handlers: RunPlannerJob, AnotherPlanner
```

This catches configuration errors early rather than at runtime when jobs are processed.

---

## LISTEN/NOTIFY Wake-ups

Workers use PostgreSQL LISTEN/NOTIFY to wake up immediately when jobs arrive.

### Channel

```kotlin
const val JOB_NOTIFICATIONS_CHANNEL = "job_notifications"
```

### Trigger

Jobs table has a trigger that sends notifications on insert:

```sql
CREATE FUNCTION notify_job_ready() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('job_notifications', NEW.id::text);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

### WakeUpGate

```kotlin
val gate = WakeUpGate()

// In worker loop
while (true) {
    val jobs = LeaseJobs(workerId, limit = 10)

    if (jobs.isEmpty()) {
        // Wait for notification or timeout
        gate.waitForWakeUp(timeoutMs = 30_000)
    }

    // Process jobs...
}
```

### JobWakeupListener

Manages the LISTEN connection with auto-reconnect:

```kotlin
val listener = JobWakeupListener(
    jdbcUrl = "jdbc:postgresql://localhost/mydb",
    gate = wakeUpGate,
    reconnectPolicy = ReconnectPolicy.exponentialBackoff()
)

listener.start()
// ... later
listener.stop()
```

---

## Usage Examples

### Complete Worker Loop with Graceful Shutdown

```kotlin
class JobWorker(
    private val pgRest: PostgRestClient
) {
    private val processor = JobProcessor(batchSize = 10, concurrency = 5)
    private val gate = WakeUpGate()
    private val listener = JobWakeupListener(jdbcUrl, gate)

    suspend fun run() {
        // Log discovered handlers and start listener
        JobRegistry.logDiscovered(logger)
        listener.start()

        // Process jobs until shutdown
        while (processor.shouldContinue()) {
            val count = context(pgRest) {
                either { processor.processBatch() }
            }.getOrElse {
                logger.error { "Failed to process batch: $it" }
                delay(1000)
                continue
            }

            if (count == 0) {
                gate.waitForWakeUp(30_000)
            }
        }

        listener.stop()
    }

    /**
     * Gracefully stop processing.
     * Call from shutdown hook or signal handler.
     */
    suspend fun shutdown() {
        val completed = processor.shutdown(timeout = 2.minutes)
        if (!completed) {
            logger.warn { "Shutdown timed out, some jobs may need stale recovery" }
        }
    }
}

// Usage with JVM shutdown hook
fun main() = runBlocking {
    val worker = JobWorker(pgRest)

    Runtime.getRuntime().addShutdownHook(Thread {
        runBlocking {
            worker.shutdown()
        }
    })

    worker.run()
}
```

### Graceful Shutdown API

The `JobProcessor` supports graceful shutdown to prevent leaving jobs in `processing` state:

```kotlin
val processor = JobProcessor()

// In worker loop
while (processor.shouldContinue()) {
    processor.processBatch()
    // ...
}

// From shutdown hook or signal handler
suspend fun onShutdown() {
    // Option 1: Request and wait (blocking)
    val completed = processor.shutdown(timeout = 2.minutes)

    // Option 2: Request only (non-blocking)
    processor.requestShutdown()
    // ... do other cleanup ...
    processor.shutdown()  // wait later
}
```

**Shutdown behavior:**

- `shouldContinue()` returns `false` after shutdown requested
- `processBatch()` returns 0 without leasing new jobs
- In-flight jobs complete normally (not cancelled)
- `shutdown(timeout)` waits for in-flight jobs or returns `false` if timed out

**If timeout expires:** Jobs still processing will have their leases expire eventually, and stale lease recovery will
return them to the queue.

### Enqueuing from Webhook Handler

```kotlin
object StripeWebhookHandler {
    context(pgRest: PostgRestClient, _: Raise<PostgRestError>)
    fun handlePaymentReceived(event: StripeEvent, surfaceId: UUID) {
        // 1. Record fact in ledger
        RecordExternalFact(...)

        // 2. Enqueue planner job
        EnqueueJob(
            EnqueueJobInput(
                jobType = "run_planner",
                targetType = "surface",
                targetId = surfaceId,
                idempotencyKey = "planner_after_${event.id}"
            )
        )

        // 3. Return 200 OK (job runs async)
    }
}
```

---

## Tests

**Tests for jobs are located in `libraries/jobs-runtime`.**

See [jobs-runtime/README.md](../jobs-runtime/README.md) for test documentation.

```bash
./gradlew :libraries:jobs-runtime:test
```

---

## Related Modules

- **modules/ledger** — Event-sourced entitlement journal (jobs process ledger facts)
- **modules/ledger-planner** — Computes reconciliation plans
- **modules/ledger-executor** — Executes plan actions against surfaces
- **libraries/postgrest** — PostgREST client for database access
- **libraries/flyway** — Migration management
