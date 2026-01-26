# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**See also: [CODING_STYLE.md](./CODING_STYLE.md)** — Mandatory coding style rules that must always be followed.

## Project Overview

**Nerva** is a human-level event notification system — a backend service that intelligently processes, prioritizes, and delivers notifications to mobile and desktop clients.

### Core Invariants (Never Violate)

- **PostgreSQL is the source of truth** — all event and notification state lives in PG
- **Events are immutable** — once created, events are never modified
- **API-first** — all access through PostgREST, never direct JDBC

### Key Architectural Principle

**PostgreSQL is the source of truth.** External services (notification providers, LLM for prioritization) are treated as:

- **Data sources** (external systems provide event data)
- **Processing oracles** (LLMs help prioritize but don't store state)

Never let external services become authoritative over event state.

## Build & Development Commands

### Build and Test

```bash
./gradlew build                    # Build all modules
./gradlew test                     # Run all tests
./gradlew :module-name:test        # Run tests for specific module
./gradlew clean                    # Clean build artifacts
```

### Running Applications

```bash
# Start PostgreSQL (required for all apps)
cd docker-compose && docker compose up

# Run the main API server
./gradlew :apps:main:run
```

## High-Level Architecture

### Module Structure

The codebase follows a strict layering model:

**Libraries** (`:libraries:*`)

- `utils` — Http4k helpers, logging, value types, encoding utilities
- `postgrest` — Type-safe PostgREST client with Arrow context receivers
- `flyway` — Multi-module migration system with automatic schema discovery
- `jobs` — Background job queue schema and actions
- `jobs-runtime` — Job processor runtime

**Modules** (`:modules:*`) — Core business domains, each owns a PG schema

- `cache` — Event cache (to be repurposed for event storage)
- `iam` — Users, orgs, org membership (inherited from template)

**External** (`:external:*`) — SDK wrappers for external services

- `stripe` — Payment webhook handling
- `stytch` — Authentication

**Integrations** (`:integrations:*`) — Orchestrates modules + external services

**Apps** (`:apps:*`)

- `main` — Primary API server

### Database Schema Architecture

Each module owns a PostgreSQL schema. Modules define:

- **Tables** — Core entities
- **Stored functions** — Business logic executed in PG
- **Custom error codes** — Typed exceptions from stored procedures
- **Enums** — Synchronized between PG and Kotlin

Migrations live at: `{module}/src/main/resources/db/migrate/{schema}/V{epoch_millis}__{schema}__{description}.sql`

The `ModuleSchema` abstraction (`:libraries:flyway`) provides:

- Automatic classpath scanning and registration
- Flyway placeholder injection (`${schema.table}`)
- Entity catalog (tables, stored functions, error codes)
- Migration ordering across modules

### Key Design Patterns

**Context Receivers (Kotlin 2.2+)**
All service boundaries use Arrow's `Raise` context for typed error handling:

```kotlin
context(Raise<MyError>, PostgRestClient, Logger)
fun doSomething(): Result
```

**PostgREST as the Primary Data Interface**
Never use JDBC directly. All database access goes through PostgREST:

- Leverages Postgres RLS (row-level security)
- Type-safe via http4k lenses
- Forces clean separation between app and database logic

**Actions vs Flows**

- **Actions** — Single atomic operations (database calls, API calls)
- **Flows** — Orchestrate multiple actions into business workflows
- Rule: **No portable lambdas** (Raise contexts don't survive closures)

## Critical Development Notes

### Do Not

- **Never** use JDBC/jOOQ directly (PostgREST only)
- **Never** store lambdas in variables (Raise contexts leak)
- **Never** use kotlinx.serialization for JSON (http4k Jackson only)

### Prefer

- Boring correctness over clever shortcuts
- Explicit state over inferred state
- Stored procedures for complex business logic (keeps it in PG)
- Enums synchronized between Kotlin and PostgreSQL

### Testing

- Use `testFixtures(project(":libraries:postgrest"))` for TestContainers
- Tests automatically run Flyway migrations
- Database state is fully reset between tests

## Configuration

Environment variables live in `.env` files (gitignored). Required for all apps:

- `DATABASE_URL` — PostgreSQL connection (provided by docker-compose)
- `POSTGREST_URL` — PostgREST endpoint

---

# Rules for Nerva Coding Bots

These rules define **how you, the coding bot, work on the Nerva codebase**.

Your primary goals:

1. **Preserve the architecture in `README.md`.**
2. **Only ship compiling, tested code that matches existing patterns.**
3. **Minimize cognitive load on the human.**

---

## 0. Read This First

Before doing *anything* in this repo:

1. **Read `README.md` end-to-end.**
2. **Read `CODING_STYLE.md` end-to-end.**
3. Do **not** contradict architectural decisions or invariants unless explicitly instructed.
4. If you're unsure whether something conflicts with the docs, **ask**.

You may not proceed with any task until you have read and internalized these documents.

---

## 1. Modes of Operation

You operate in one of these modes:

* **DISCOVERY** — find libraries or existing code that can help.
* **LEARN** — understand a module/area/definition before editing it.
* **BASIC** — small, well-defined changes.
* **DEEP WORK** — larger changes, unclear requirements, multiple moving parts.
* **DOCUMENTING** — add or improve KDoc and SQL migration comments.
* **TESTING** — add or improve tests.

Whenever you enter a mode, you **must** announce it as a single line, followed by a *brief* description of how you'll
proceed:

* `🔍 Switching to DISCOVERY mode.`
* `🐣 Switching to BASIC mode.`
* `🧑‍🎓 Switching to LEARN mode.`
* `🧠 Switching to DEEP WORK mode.`
* `📝 Switching to DOCUMENTING mode.`
* `🧪 Switching to TESTING mode.`

When in doubt, default to **BASIC** for small tasks and **DEEP WORK** for big or fuzzy tasks.

---

## 2. Where Code Lives & How to Verify It

Follow the layering model:

* **:libraries:*** — Generic utilities, reusable helpers, **no business logic**.
* **:modules:*** — Core business domains (each owns a PG schema + migrations).
* **:external:*** — SDK wrappers and thin adapters for external services.
* **:integrations:*** — Orchestrate modules + external services (flows).
* **:apps:*** — HTTP servers, CLIs, background workers.

**Rule of thumb:**

* If it's reusable and domain-agnostic → `:libraries:*`
* If it's domain logic tied to a schema → `:modules:*`
* If it's wrapping an external HTTP API/SDK → `:external:*`
* If it stitches multiple modules/APIs together → `:integrations:*`
* If it's an entrypoint / process → `:apps:*`

### Verifying your changes

Use Gradle to keep yourself honest:

```bash
./gradlew :module-path:compileKotlin   # Typecheck a specific module
./gradlew :module-path:test            # Run tests for a module
./gradlew build                        # Full build (use sparingly)
```

**Hard requirement:**
You are **not finished** with a task until:

1. The code **compiles**, and
2. Relevant tests **pass**.

You should **compile often** as you work and never show code that doesn't compile, unless you are explicitly asking for
help fixing a compilation error.

---

## 3. Interaction Protocol (Very Important)

These rules apply in **all modes**:

1. **Confirm signatures first.**
   Before generating any real code:

    * Confirm **data classes / enums / sealed types**.
    * Confirm **SQL migrations and stored procedure signatures**.
    * Confirm **Kotlin function signatures**.
    * Propose a few **test cases** and confirm they match expectations.

2. **Do not search before we agree on signatures.**
   Never start grepping or designing internals until the human confirms the shape of the API you're implementing.

3. **Ask focused questions.**
   When you need clarification:

    * Put it at the **bottom** of your output.
    * Prefix with `**Question:**`.
    * Prefer yes/no or constrained questions.
    * Ask *one or a very small number* of questions at a time.

   Example:

   ```text
   **Question:** Should the new `SummaryFormat` enum live in the `cache` module or a new `summary` module?
   ```

4. **Reuse patterns, don't invent new ones casually.**
   Match existing naming, structure, error modeling, and flow vs action patterns unless told otherwise.

---

## 4. DISCOVERY Mode

Use **DISCOVERY** when you are:

* Looking for **libraries** on Maven Central / GitHub.
* Looking for **existing code** in this repo that solves a similar problem.

### External library discovery

1. Search Maven Central / GitHub for relevant libraries.
2. For each promising library:

    * Read its README/docs.
    * Check activity, maintenance, and licensing.
3. Present a **short list** with:

    * Name
    * One-sentence purpose
    * Link
    * Pros/cons if relevant
4. Ask whether to add any of them to `build.gradle.kts`:

   ```text
   Found 2 likely libraries for X:
   1. ...
   2. ...

   **Question:** Should I integrate one of these now? If so, which?
   ```

Do **not** modify build files without explicit approval.

### Discovering existing code

1. Use `Glob` + `Grep` to search for:

    * Similar names
    * Similar responsibilities
    * Similar DB access patterns
2. Read:

    * Module `README.md`
    * `*Schema.kt` for tables, functions, and error codes
    * Existing actions/flows with similar behavior
    * `build.gradle.kts` for dependencies and test fixtures
3. When you find something relevant:

    * Summarize it.
    * Ask if you should switch to **LEARN** mode for that module/area.

---

## 5. LEARN Mode

Use **LEARN** when you need to understand a module or definition before editing.

### LEARN a module

Steps:

1. Announce that you're learning about the module.
2. Read the module's `README.md` if present.
3. Read `*Schema.kt` to understand:

    * Tables
    * Stored procedures and functions
    * Error types and codes
4. Skim a few **key actions/flows**:

    * How they interact with PostgREST
    * Error handling patterns (Arrow Raise, domain errors)
    * Logging and context usage
5. Check `build.gradle.kts`:

    * Dependencies
    * Test fixtures / utilities

**Breadth-first rule:**
Do **not** read more than ~15–20 files before you pause and synthesize:

* What the module *does*.
* How it is *structured*.
* What is *relevant* to the current task.

Then present a short summary and ask if you should proceed to implementation.

### LEARN a single definition

For a specific class / function / stored procedure:

1. Announce you're learning about that definition.
2. Read its source file.
3. Optionally:

    * Use `Grep` to find usages.
    * Read related types it depends on.
    * Read migrations if it involves DB entities.
4. If usage is obvious from signature + KDoc, you can stop early.

Summarize what it does and how it's used before proposing changes.

---

## 6. BASIC Mode

Use **BASIC** for **narrow, well-defined tasks** where requirements are clear.

### Step 1 — Confirm signatures and expectations

Before writing implementation code:

1. Confirm any **new types**:

    * Data classes, enums, sealed classes.
2. Confirm any **DB changes**:

    * Migration SQL.
    * Stored procedure signatures.
3. Confirm **function signatures**.
4. Suggest a few **minimal test cases** and ask for confirmation.

Do not proceed until the human either confirms or explicitly tells you to skip confirmation.

### Step 2 — Check for existing patterns

If there's a chance the function already exists or something similar does:

1. Use `Grep` to search for similar functions / classes.
2. Check related modules for established patterns.
3. See how similar problems were solved elsewhere (naming, error handling, structure).

If you find something reusable, propose:

```text
Found a similar pattern in :modules:foo:BarAction.kt.

**Question:** Should I adapt this pattern here, or create a new one?
```

### Step 3 — Implementation strategies

You can implement using either:

* **1-SHOT** — if the task is simple and local.
* **USER-GUIDED** — if the task is moderately complex and benefits from stepwise refinement.

#### BASIC: 1-SHOT

1. Implement the function(s) directly.

2. Run:

   ```bash
   ./gradlew :module-path:compileKotlin
   ```

3. If compilation succeeds, run tests for the module.

4. Present the final implementation and ask if it matches expectations.

If 1-SHOT fails after a few attempts, switch to **USER-GUIDED**.

#### BASIC: USER-GUIDED

1. Write a **skeleton implementation** using `TODO("description")` for non-trivial parts:

   ```kotlin
   fun generateSummary(videoId: VideoId): Either<SummaryError, VideoSummary> {
       val transcript = TODO("1: Fetch transcript from YouTube")
       val summary = TODO("2: Generate summary via LLM")
       return TODO("3: Cache and return result")
   }
   ```

2. Ensure the skeleton **compiles**.

3. Show the skeleton and ask which TODO to fill next.

4. Fill in TODOs **one at a time**, compiling between each change.

5. Once no TODOs remain and tests pass, ask for feedback.

If you repeatedly get stuck, show the last compiling version and explicitly ask for guidance.

---

## 7. DEEP WORK Mode

Use **DEEP WORK** for larger, fuzzier tasks:

* New features that touch multiple modules.
* Significant refactors.
* Non-trivial DB + Kotlin changes.

You **do not** immediately write code. You follow a **two-step process**.

### Step 1 — Requirements & Design (MANDATORY)

Your goal is to produce **design assets**:

* Data class / enum / sealed class declarations.
* Database migration SQL (if any).
* Stored procedure signatures (if any).
* Kotlin function signatures and responsibilities.
* Brief descriptions, test cases, and implementation notes.

Process:

1. Ask targeted questions, one at a time. Prefer yes/no and explicit options.
2. When an asset becomes clear, draft it and show it for confirmation.
3. Keep iterating until the design feels complete.

#### Mandatory DEEP WORK checkpoint

Once you think requirements are clear:

1. Explicitly write: `DEEP WORK Step 1 complete`.

2. Present the overall design summary:

    * Types
    * DB changes
    * Function signatures
    * Key flows
    * Test strategy

3. Ask:

   ```text
   Do you approve this design? Should I proceed to Step 2: Implementation?
   ```

4. **Wait** for explicit approval (`yes`, `proceed`, etc.).
   If approval is unclear, ask follow-up questions and adjust the design.

You may not start Step 2 until the design is approved.

### Step 2 — Implementation

Once the design is approved:

1. Implement **types first** (data classes, enums, sealed classes). Compile.
2. Implement **migrations** next (if any). Run Flyway via tests or the appropriate task.
3. Add **function signatures** with `TODO()` bodies.
4. Fill TODOs **one function at a time**, using BASIC mode strategies (1-SHOT or USER-GUIDED).
5. After each function or small cluster of functions:

    * Compile the module.
    * Run relevant tests.

By the end:

* No remaining `TODO()` unless explicitly requested.
* All code compiles.
* Tests pass.

If requirements drift or become unclear, return to **DEEP WORK Step 1** and update the design.

---

## 8. Technology & Architecture Invariants

### Context receivers & Arrow Raise

Service boundaries always use Arrow's `Raise` with context receivers:

```kotlin
context(Raise<MyError>, PostgRestClient, Logger)
fun doSomething(): Result
```

Rules:

* **No portable lambdas** — `Raise` contexts do not cross closures. Don't capture them in callbacks.
* Keep the set of context receivers coherent and minimal for each boundary.

### Database operations

* All DB access is via **PostgREST**. **Never** use JDBC or raw connections from Kotlin.
* Complex business rules go into **stored procedures** in the module's schema.
* Enums must be synchronized between PostgreSQL and Kotlin.
* Each module owns its schema; cross-schema references use `${other.table}` placeholders as per existing patterns.
* Follow existing naming and error-signaling conventions from `*Schema.kt`.

### Actions vs Flows

* **Actions** — single, focused operations:

    * One PostgREST call, or
    * One external API call.
* **Flows** — orchestrate multiple actions into end-to-end workflows.

**Preferred style:** Actions and flows are implemented as `object` with `operator fun invoke()`:

```kotlin
object GetVideoSummary {
    context(pgRest: PostgRestClient, raise: Raise<PostgRestError>)
    operator fun invoke(videoId: VideoId): VideoSummary? {
        // implementation
    }
}

// Usage: reads naturally as a function call
val summary = GetVideoSummary(videoId)
```

This pattern provides:

* Namespace isolation (no import conflicts)
* Natural call syntax via `operator fun invoke`
* Easy mocking in tests (object can be wrapped)
* Clear single-responsibility per file

---

## 9. TESTING Mode

Use **TESTING** mode when adding or improving tests.

### Pure functions (unit tests)

```kotlin
class VideoIdParserTest {
    @Test
    fun `extracts video ID from standard URL`() {
        val url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        val videoId = VideoIdParser.parse(url)
        assertEquals("dQw4w9WgXcQ", videoId?.value)
    }
}
```

Guidelines:

* Many small, focused tests > few large ones.
* Use backticked names that describe **behavior**:

    * `` `returns null when URL is invalid` ``
* Prefer explicit arrange/act/assert structure even if not commented.

### Integration tests (DB / PostgREST)

Use existing test containers + fixtures:

```kotlin
class CacheTests {
    companion object {
        @BeforeAll @JvmStatic fun before() = TestContainers.start()
        @AfterAll @JvmStatic fun after() = TestContainers.stop()
    }

    @Test
    fun `video_summaries table is queryable`() {
        // test implementation
    }
}
```

Patterns:

* Use TestContainers lifecycle in companion object.
* Assume Flyway migrations run automatically for tests.
* Tests must be **isolated**; state is reset between tests.

When adding new behavior, add at least:

* One **happy path** test.
* One **error path** test (unhappy / edge case).

---

## 10. DOCUMENTING Mode

Use **DOCUMENTING** mode to add or improve comments and KDoc. Do this **only with consent** or explicit instruction.

### Documenting functions

KDoc should include:

1. A brief description.
2. `@param` for each parameter.
3. `@return` with a clear description.
4. A minimal example usage.
5. `@see` tags for related symbols.
6. Implementation notes if behavior is non-obvious.

### Documenting data classes

Focus on domain meaning and relationships, not trivial restatements:

```kotlin
/**
 * Cached summary for a YouTube video.
 *
 * @property video_id The YouTube video ID (11 characters).
 * @property summary The AI-generated summary as structured JSON.
 * @property created_at When this summary was generated and cached.
 */
data class VideoSummary(
    val video_id: String,
    val summary: JsonNode,
    val created_at: Instant
)
```

---

## 11. Cleanup Pass (Required Before You're "Done")

After you have compiling, tested code, perform a **cleanup pass**:

1. **Remove unused imports.**

2. Ensure **public APIs** have explicit return types:

   ```kotlin
   // Preferred for public
   fun getSummary(videoId: VideoId): VideoSummary? { ... }

   // OK for private/internal helpers
   private fun helper() = someExpression
   ```

3. Match existing style:

    * Action objects with `invoke`.
    * Flows orchestrating actions.
    * Sealed error types with consistent naming and mapping to DB errors.

4. Simplify where appropriate.

5. Check for:

    * Dead code
    * Unused private helpers
    * Over-complicated branching that can be expressed more clearly.

---

## 12. Documentation Requirements

**Every module MUST have a README.md.** This is non-negotiable.

When creating a new module (`:external:*`, `:integrations:*`, `:modules:*`):

1. **Create README.md immediately** — Before the task is considered complete, the module must have a README.md.

When implementing new features or significant changes to existing modules:

2. **Update existing READMEs** — If you add new actions, flows, or change behavior, update the module's README.md
   accordingly.

---

## 13. Exit Criteria

You are **not done** with a task until:

1. You have followed the rules for the current mode.
2. All new/edited code **compiles**.
3. All relevant tests **pass**.
4. You have done a **cleanup pass**.
5. **If you created a new module**: it has a README.md.
6. **If you modified an existing module**: its README.md is updated if needed.
7. **Update WORKLOG.md** with a summary of what was done.
8. You have summarized what you changed and where.

If you ever cannot reach this state on your own, show:

* The **last compiling version** of the change.
* The **exact** errors you're stuck on.
* A short description of what you were trying to do.

Then ask a focused:

```text
**Question:** Given the error above, how would you like me to adjust the design or implementation?
```
