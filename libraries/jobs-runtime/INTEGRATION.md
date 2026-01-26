# Jobs Runtime Integration Tests

This document describes the integration test suite for the jobs-runtime library. These tests validate the
PostgreSQL-backed job queue under realistic conditions including concurrency, failures, and network issues.

---

## Quick Start

```bash
# Run all integration tests
./gradlew :libraries:jobs-runtime:integrationTest

# Run a specific test class
./gradlew :libraries:jobs-runtime:integrationTest --tests "dev.dailywombat.jobs.integration.LeaseExclusivityConcurrencyIT"

# Run with verbose output
./gradlew :libraries:jobs-runtime:integrationTest --info
```

Tests require Docker to be running (for TestContainers).

---

## Test Environment

### Infrastructure

The integration tests use TestContainers to spin up:

1. **PostgreSQL** (postgres:16) - The job queue database
2. **PostgREST** - REST API for database access

Both containers are started once per test run and shared across all tests for efficiency.

### Key Classes

| Class                | Location                        | Purpose                                                        |
|----------------------|---------------------------------|----------------------------------------------------------------|
| `JobsIntegrationEnv` | `support/JobsIntegrationEnv.kt` | Singleton that manages containers and provides `pgRest` client |
| `JobsDb`             | `support/db/JobsDb.kt`          | Direct JDBC helpers for test assertions (bypasses PostgREST)   |
| `Await`              | `support/Await.kt`              | Polling helpers for async assertions                           |
| `TestWorker`         | `support/TestWorker.kt`         | Complete worker wrapper for E2E tests                          |

### Test Lifecycle

```kotlin
class MyIT {
    companion object {
        @BeforeAll @JvmStatic
        fun beforeAll() {
            JobsIntegrationEnv.start()  // Starts containers (idempotent)
        }
    }

    @BeforeEach
    fun beforeEach() {
        JobsIntegrationEnv.resetJobs()  // Truncates jobs table
        ResetTestJobs()                  // Resets test handler state
    }
}
```

### Test Job Handlers

Located in `support/testjobs/`:

| Handler               | Type String               | Behavior                                 |
|-----------------------|---------------------------|------------------------------------------|
| `SuccessJob`          | `test_success`            | Always succeeds immediately              |
| `FailJob`             | `test_fail`               | Always fails (returns `JobResult.Retry`) |
| `SlowJob`             | `test_slow`               | Delays for configurable duration         |
| `FailUntilAttemptJob` | `test_fail_until_attempt` | Fails K-1 times, succeeds on attempt K   |

All handlers track invocation counts via `AtomicInteger` for assertions.

---

## Test Categories

The tests are organized into three categories:

### 1. Database Mechanics (Direct SQL/PostgREST)

These tests validate the stored procedures and SQL logic without involving the worker/processor.

### 2. Processor Behavior

These tests use `JobProcessor` directly to validate job execution, retry logic, and error handling.

### 3. E2E Worker Tests

These tests use `TestWorker` which wraps both `JobProcessor` and `JobWakeupListener` to test the complete system
including LISTEN/NOTIFY.

---

## Test Descriptions

### A) EnqueueIdempotencyRaceIT

**File:** `EnqueueIdempotencyRaceIT.kt`

**What it validates:**

- Idempotency key uniqueness under concurrent load
- `ON CONFLICT DO NOTHING` behavior in `enqueue_job()`

**Scenario:**

1. Launch 10 concurrent coroutines
2. Each enqueues a job with the same `idempotency_key`
3. Assert exactly 1 job exists in the database

**Key assertion:**

```kotlin
val count = JobsDb.countJobsWithIdempotencyKey(conn, jobType, idempotencyKey)
count shouldBe 1
```

**Why it matters:** Prevents duplicate work when the same event triggers multiple enqueue attempts (e.g., webhook
retries).

---

### B) LeaseExclusivityConcurrencyIT

**File:** `LeaseExclusivityConcurrencyIT.kt`

**What it validates:**

- `SKIP LOCKED` prevents double-processing
- No job is processed more than once
- All jobs are eventually processed

**Scenario:**

1. Enqueue 200 jobs
2. Launch 10 concurrent workers
3. Each worker repeatedly calls `LeaseJobs` and processes
4. Track which jobs each worker processed
5. Assert no overlaps and all 200 jobs completed

**Key assertion:**

```kotlin
// No job processed by multiple workers
val duplicates = allProcessed.groupBy { it }.filter { it.value.size > 1 }
duplicates shouldBe emptyMap()

// All jobs processed
allProcessed.distinct().size shouldBe 200
```

**Why it matters:** Core guarantee that concurrent workers don't duplicate work.

---

### C) AvailableAtGatingIT

**File:** `AvailableAtGatingIT.kt`

**What it validates:**

- Jobs with `available_at` in the future are not leased
- Jobs become leasable after `available_at` passes

**Scenario:**

1. Enqueue a job with `available_at = now + 5 seconds`
2. Immediately try to lease - should get nothing
3. Wait 5 seconds
4. Lease again - should get the job

**Key assertion:**

```kotlin
// Before available_at
val beforeLease = LeaseJobs(workerId, limit = 10)
beforeLease shouldBe emptyList()

// After available_at passes
delay(5.seconds)
val afterLease = LeaseJobs(workerId, limit = 10)
afterLease.size shouldBe 1
```

**Why it matters:** Enables scheduled/delayed jobs and retry backoff.

---

### D) PriorityOrderingIT

**File:** `PriorityOrderingIT.kt`

**What it validates:**

- Higher priority jobs are leased before lower priority
- `ORDER BY priority DESC` in `lease_jobs()`

**Scenario:**

1. Enqueue 3 jobs with priorities 10, 1, 5
2. Lease with `limit = 1` three times
3. Assert jobs come out in order: priority 10, then 5, then 1

**Key assertion:**

```kotlin
val priorities = leasedJobs.map { it.priority }
priorities shouldBe listOf(10, 5, 1)
```

**Why it matters:** Ensures critical jobs (high priority) are processed first during backlogs.

---

### E) LeaseExpiryRecoveryIT

**File:** `LeaseExpiryRecoveryIT.kt`

**What it validates:**

- Jobs with expired leases are recovered
- Different worker can lease a "stuck" job
- `lease_count` increments but `attempts` doesn't

**Scenario:**

1. Enqueue a job
2. Worker A leases with short lease duration
3. Simulate crash (don't complete the job)
4. Wait for lease to expire
5. Worker B leases - should get the same job

**Key assertion:**

```kotlin
// Worker B gets the abandoned job
val recoveredJobs = LeaseJobs(workerB, limit = 10)
recoveredJobs.size shouldBe 1
recoveredJobs[0].id shouldBe jobId
recoveredJobs[0].leaseCount shouldBe 2  // Leased twice
recoveredJobs[0].attempts shouldBe 0     // No execution failure
```

**Why it matters:** Handles worker crashes without manual intervention.

---

### F) CompleteOwnershipIT

**File:** `CompleteOwnershipIT.kt`

**What it validates:**

- Only the lease owner can complete/fail a job
- Wrong worker ID returns `NOT_FOUND`
- Prevents race conditions in job completion

**Scenario:**

1. Worker A leases a job
2. Worker B (different ID) tries to complete it
3. Assert `CompleteJob` returns `false`
4. Worker A completes it - succeeds

**Key assertion:**

```kotlin
// Wrong owner can't complete
CompleteJob(jobId, workerB) shouldBe false

// Right owner can complete
CompleteJob(jobId, workerA) shouldBe true
```

**Why it matters:** Prevents stale workers from completing jobs that were already recovered and re-assigned.

---

### G) RetryBackoffMathIT

**File:** `RetryBackoffMathIT.kt`

**What it validates:**

- Exponential backoff formula: `min(base * 2^attempts, max)`
- Jitter: ±25% randomness
- Cap at maximum backoff

**Scenario:**

1. Enqueue a job
2. Fail it repeatedly with different attempt counts
3. Check `available_at` matches expected backoff with jitter tolerance

**Formula:**

```
backoff = min(base_seconds * 2^attempts, max_backoff_seconds)
actual_delay = backoff * random(0.75, 1.25)  // ±25% jitter
```

**Key assertion:**

```kotlin
// For attempt 2 with base=30s: expected = 30 * 2^2 = 120s
val expectedBase = 30 * (1 shl attempt)
val minDelay = (expectedBase * 0.75).toLong()
val maxDelay = (expectedBase * 1.25).toLong()

actualDelay.inWholeSeconds shouldBeInRange minDelay..maxDelay
```

**Why it matters:** Validates retry timing to prevent thundering herd and ensure reasonable retry intervals.

---

### H) WorkerDrainsQueueIT

**File:** `WorkerDrainsQueueIT.kt`

**What it validates:**

- TestWorker processes all jobs to completion
- End-to-end flow from enqueue to complete
- Proper cleanup and job counting

**Scenario:**

1. Enqueue 50 `SuccessJob` jobs
2. Start TestWorker
3. Wait for queue to drain
4. Assert all 50 completed

**Key assertion:**

```kotlin
Await.queueDrained(timeout = 30.seconds)
SuccessJob.invocations.get() shouldBe 50
```

**Why it matters:** Validates the complete happy-path flow.

---

### I) WorkerRetryThenSuccessIT

**File:** `WorkerRetryThenSuccessIT.kt`

**What it validates:**

- Job fails K-1 times, succeeds on attempt K
- Retry mechanism works correctly
- Final state is `completed`, not `failed`

**Scenario:**

1. Enqueue `FailUntilAttemptJob` with `succeedOnAttempt = 3`
2. Start TestWorker with short backoff (1 second)
3. Wait for job to complete
4. Assert job was invoked 3 times and ended in `completed` status

**Key assertion:**

```kotlin
Await.jobStatus(jobId, "completed", timeout = 30.seconds)
FailUntilAttemptJob.invocationCount(targetId) shouldBe 3
```

**Why it matters:** Validates the retry-then-succeed pattern used for transient failures.

---

### J) NotifyWakeupLatencyIT

**File:** `NotifyWakeupLatencyIT.kt`

**What it validates:**

- LISTEN/NOTIFY wakes worker within acceptable latency
- Jobs are processed quickly after enqueue (< 2 seconds)

**Scenario:**

1. Start TestWorker (includes JobWakeupListener)
2. Record timestamp
3. Enqueue a job
4. Wait for completion
5. Assert total latency < 2 seconds

**Key assertion:**

```kotlin
val elapsed = System.currentTimeMillis() - startTime
elapsed shouldBeLessThan 2000  // 2 seconds max
```

**Why it matters:** Validates that NOTIFY provides low-latency job processing vs polling.

---

### K) NotifyMissedStillWorksIT

**File:** `NotifyMissedStillWorksIT.kt`

**What it validates:**

- Polling fallback when NOTIFY is missed
- Jobs still processed when listener is stopped
- System degrades gracefully

**Scenario:**

1. Start TestWorker with 2-second poll interval
2. Stop only the LISTEN listener (worker loop continues)
3. Enqueue a job (NOTIFY will be missed)
4. Assert job completes via polling within `pollTimeout + cushion`

**Key assertion:**

```kotlin
worker.stopListenerOnly()
val jobId = enqueueJob()

// Job should complete via polling (not NOTIFY)
Await.jobStatus(jobId, "completed", timeout = 10.seconds)
```

**Why it matters:** Ensures system remains functional even if LISTEN connection is lost.

---

## Test Helpers

### Await

Polling helpers for async assertions:

```kotlin
// Wait for specific job status
Await.jobStatus(jobId, "completed", timeout = 10.seconds)

// Wait for queue to be empty
Await.queueDrained(timeout = 30.seconds)

// Wait for custom condition
Await.condition(timeout = 5.seconds, description = "something") {
    someConditionIsTrue()
}
```

### JobsDb

Direct JDBC access for assertions (bypasses PostgREST):

```kotlin
JobsDb.withConnection { conn ->
    // Fetch job by ID
    val job = JobsDb.fetchJob(conn, jobId)

    // Count jobs by status
    val counts = JobsDb.countByStatus(conn)

    // Count with specific idempotency key
    val count = JobsDb.countJobsWithIdempotencyKey(conn, jobType, key)
}
```

### TestWorker

Complete worker wrapper for E2E tests:

```kotlin
val worker = TestWorker(
    batchSize = 10,
    maxAttempts = 3,
    backoffSeconds = 1,    // Short backoff for tests
    pollTimeoutMs = 2000   // 2-second polling
)

worker.start()

// Wait for jobs to process
worker.awaitDrained(timeout = 30.seconds)

// Or wait for specific count
worker.awaitProcessedCount(expected = 50)

// Graceful shutdown
worker.stop()

// For NOTIFY-missed tests
worker.stopListenerOnly()
```

### dumpState

On assertion failure, dump current database state for debugging:

```kotlin
val jobId = enqueueJob() ?: throw AssertionError(
    "Failed to enqueue job\n${JobsIntegrationEnv.dumpState()}"
)
```

---

## Time Tolerance

Integration tests use tolerant time assertions to account for:

- Container startup variance
- Network latency
- CI environment variability

**Guidelines:**

- Use `±500ms` tolerance for time-sensitive assertions
- Use `shouldBeInRange` instead of exact equality
- Allow extra time for first test in a suite (container warmup)

```kotlin
// Good: tolerant
actualDelay.inWholeSeconds shouldBeInRange (expected - 1)..(expected + 1)

// Bad: brittle
actualDelay.inWholeSeconds shouldBe expected
```

---

## Debugging Failed Tests

### 1. Check container logs

```bash
docker logs $(docker ps -q --filter ancestor=postgres:16)
```

### 2. Use dumpState

Add to failing assertions:

```kotlin
println(JobsIntegrationEnv.dumpState())
```

### 3. Increase timeouts temporarily

```kotlin
Await.jobStatus(jobId, "completed", timeout = 60.seconds)  // Debug: longer timeout
```

### 4. Run single test with verbose output

```bash
./gradlew :libraries:jobs-runtime:integrationTest \
    --tests "*.LeaseExclusivityConcurrencyIT" \
    --info
```

---

## Adding New Tests

1. Create test class in `src/integrationTest/kotlin/dev/dailywombat/jobs/integration/`
2. Follow the lifecycle pattern:
   ```kotlin
   @BeforeAll - JobsIntegrationEnv.start()
   @BeforeEach - JobsIntegrationEnv.resetJobs() + ResetTestJobs()
   @AfterEach - cleanup any worker instances
   ```
3. Use `Await` helpers for async assertions
4. Include `dumpState()` in failure messages
5. Add tolerant time assertions where needed
6. Document the test in this file

---

## Related Documentation

- [Jobs Library README](../jobs/README.md) - API documentation and usage examples
- [CLAUDE.md](../../CLAUDE.md) - Project-wide architecture and conventions
