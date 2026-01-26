# Example Module

This is a template for creating new domain modules.

## Creating a New Module

1. Copy this directory: `cp -r modules/_example modules/your-module`
2. Rename package: `s/example/your-module/g` in all files
3. Update `ExampleSchema.kt` → `YourModuleSchema.kt`
4. Add to `settings.gradle.kts`: `":modules:your-module"`
5. Add schema to `docker-compose.yaml`: `PGRST_DB_SCHEMAS`

## Structure

```
your-module/
├── build.gradle.kts           # Dependencies
├── src/main/kotlin/.../
│   ├── YourModuleSchema.kt    # ModuleSchema declaration
│   ├── model/                 # Value objects / entities
│   ├── actions/               # PostgREST operations
│   └── enums/                 # Domain enums (synced to PG)
└── src/main/resources/db/migrate/your_module/
    ├── V001__...__create-enums.sql
    ├── V002__...__create-tables.sql
    └── V003__...__grants.sql
```

## Migration Naming Convention

`V{timestamp}__{schema}__{description}.sql`

Example: `V1234567890__your_module__create-users.sql`

## Key Patterns

- Each module owns ONE PostgreSQL schema
- Enums must be synchronized between Kotlin and PostgreSQL
- Use `SECURITY DEFINER` for stored procedures
- Always grant `EXECUTE` permission to `web_anon`
