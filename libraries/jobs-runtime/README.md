# Jobs Runtime

Runtime components for executing jobs from the queue defined in `libraries/jobs`.

## Components

### JobProcessor

Leases and executes jobs with bounded concurrency.

```kotlin
val processor = JobProcessor(
    batchSize = 10,       // Jobs to lease per batch
    concurrency = 10,     // Max parallel executions
    maxAttempts = 3,      // Retries before failure
    backoffSeconds = 30   // Base exponential backoff
)

context(pgRest: PostgRestClient, _: Raise<PostgRestError>) {
    while (processor.shouldContinue()) {
        val count = processor.processBatch()
        if (count == 0) delay(pollIntervalMs)
    }
}

// Graceful shutdown
processor.shutdown(timeout = 30.seconds)
```

### JobWakeupListener

Listens for PostgreSQL NOTIFY events to wake up immediately when jobs are enqueued.

```kotlin
val listener = JobWakeupListener(
    connectionSource = { createPgConnection() },
    onWake = { processJobs() },
    scope = coroutineScope
)
listener.start()

// Later
listener.close()
```

### StaleJobRecovery

Releases jobs stuck in `processing` status with expired leases.

```kotlin
val recovery = StaleJobRecovery(
    postgRestClient = pgRest,
    interval = 30.seconds,
    limit = 100,
    scope = coroutineScope
)
recovery.start()

// Later
recovery.close()
```

### JobRegistry

Auto-discovers Job handlers via classpath scanning.

```kotlin
// At startup - validates no duplicate job types
JobRegistry.logDiscovered()

// Lookup handler
val handler: Job<*>? = JobRegistry["run_planner"]

// All registered types
val types: Set<String> = JobRegistry.types
```

## Type-Safe Enqueueing

```kotlin
import dev.dailywombat.jobs.runtime.actions.enqueue

// Type-safe: params are compile-time checked
val jobId = RunPlannerJob.enqueue(
    targetType = "surface",
    targetId = surfaceId,
    params = RunPlannerJob.Params(surfaceId = surfaceId)
)
```

## Metrics

Exposes Micrometer metrics:

| Metric                          | Type    | Description                      |
|---------------------------------|---------|----------------------------------|
| `jobs.leased`                   | Counter | Jobs leased (by job_type)        |
| `jobs.completed`                | Counter | Jobs completed (by job_type)     |
| `jobs.retried`                  | Counter | Jobs retried (by job_type)       |
| `jobs.failed`                   | Counter | Jobs failed (by job_type)        |
| `jobs.recovered`                | Counter | Stale jobs recovered             |
| `jobs.processing.duration`      | Timer   | Job execution time (by job_type) |
| `jobs.queue.depth`              | Gauge   | Queue size (by status)           |
| `jobs.queue.oldest_age_seconds` | Gauge   | Age of oldest job (by status)    |

## Tests

Location: `src/test/kotlin/dev/dailywombat/jobs/runtime/actions/`

### JobActionsTest (10 tests)

| Test                                                          | What it validates                        |
|---------------------------------------------------------------|------------------------------------------|
| `EnqueueJob should create a job and return its ID`            | Basic job creation                       |
| `EnqueueJob with idempotency key should deduplicate`          | Same idempotency key returns same job ID |
| `LeaseJobs should return empty list when no jobs available`   | Empty queue handling                     |
| `LeaseJobs should lease a pending job`                        | Job leasing with correct data            |
| `CompleteJob should mark a leased job as completed`           | Successful completion                    |
| `CompleteJob should fail for non-existent job`                | Non-existent job handling                |
| `FailOrRetryJob should retry a job when under max attempts`   | Retry scheduling                         |
| `FailOrRetryJob should fail a job when max attempts reached`  | Exhausted retries                        |
| `FailOrRetryJob should return NOT_FOUND for non-existent job` | Non-existent job handling                |

```bash
./gradlew :libraries:jobs-runtime:test
```

## Related

- [libraries/jobs](../jobs/README.md) — Job queue schema and abstractions
- [apps/job-worker](../../apps/job-worker/README.md) — Deployable worker application
