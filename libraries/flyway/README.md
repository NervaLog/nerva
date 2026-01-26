# Flyway

---

Based on your current setup—specifically a modular SaaS with classpath scanning and programmatic configuration—you are
already using Flyway more sophisticatedly than most. However, there are a few "power user" features that often get
overlooked in these types of dynamic architectures.

Given your use of Kotlin and a modular "Top Shelf" approach, here is what is likely missing from your toolkit:

---

### 1. Repeatable Migrations (`R__`) for PostgREST Views

In a PostgREST stack, you often create **API Views** to reshape internal module data for public consumption.

* **The Problem:** If you use versioned migrations (`V1__`), every time you want to add a column to a view, you have to
  create `V2`, `V3`, etc., which litters your history.
* **The Feature:** **Repeatable Migrations**. Name your file `R__create_api_views.sql`.
* **The Benefit:** Flyway will re-run this file **only when its checksum changes**. It’s perfect for
  `CREATE OR REPLACE VIEW` statements or PostgREST functions (RPCs). It keeps your module's "API Surface" in a single,
  readable file.

### 2. Error Overrides (Flyway Teams)

In a multi-module SaaS, you might occasionally hit "ignorable" errors (e.g., trying to drop an index that was already
manually dropped).

* **The Feature:** You can configure an `ErrorOverride`.
* **The Benefit:** It allows you to map specific Postgres Error Codes (like `42704` for `undefined_object`) to a "
  Warning" instead of a "Failure," preventing one small hiccup in a non-critical module from blocking your entire "Top
  Shelf" deployment.

### 3. Dry Runs (`dryRunOutput`)

Since you are merging placeholders and scanning paths from multiple modules, the final SQL being executed can sometimes
be a mystery.

* **The Feature:** `.dryRunOutput("path/to/file.sql")`.
* **The Benefit:** Before applying migrations to production, your `FlywayMigrator` can output the *entire* concatenated
  SQL script (with all placeholders resolved). You can then log this or pipe it to a security linter like `sqlfluff` as
  part of your CI/CD.

### 4. Baseline Migrations (`B__`)

As your SaaS ages, your "Basic Functionality" module might end up with 500+ migration files, slowing down the boot time
for new developer environments.

* **The Feature:** **Baseline Migrations**.
* **The Benefit:** You can consolidate `V1` through `V100` into a single `B100__initial_state.sql`. Flyway will use the
  `B` file for new databases and skip the 100 small files, significantly speeding up test suite execution.

---

### Summary Table: Advanced Feature Fit

| Feature                | Best For                     | Why it fits you                                                 |
|------------------------|------------------------------|-----------------------------------------------------------------|
| **Repeatable (`R__`)** | PostgREST Views/Functions    | Keeps API definitions clean and version-less.                   |
| **Java Migrations**    | Complex Data Transformations | Use Kotlin logic for data migrations that are too hard for SQL. |
| **Callbacks**          | PostgREST Reloading          | (We just added this!) Automates system signals.                 |
| **Dry Run**            | Audit & Compliance           | See exactly what the "Top Shelf" is doing.                      |

### Next Step Recommendation

Would you like to see how to implement a **Java-based migration** in Kotlin? It’s incredibly useful for the "Basic
Functionality" layer when you need to perform complex logic (like migrating Stytch user IDs or calling an external API)
that plain SQL can't handle.

The following video provides a visual overview of how Flyway manages multiple environments and advanced workflows, which
is useful for scaling your SaaS.

[Advanced Database Migrations with Flyway](https://www.youtube.com/watch?v=pd2EdfwResU)

This video explains dry runs and advanced deployment artifacts, helping you understand how to review SQL before it hits
your production schemas.

## Tests

**No tests currently exist for this module.**

Priority test cases needed:

- ModuleSchema registration and placeholder injection
- FlywayMigrator migration execution
- Custom error code detection
- Multi-module migration ordering

```bash
./gradlew :libraries:flyway:test
```