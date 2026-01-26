# Example Integration

This is a template for connecting domain modules to external services.

## Creating a New Integration

1. Copy this directory: `cp -r integrations/_example integrations/your-integration`
2. Update `build.gradle.kts` dependencies to point to your module and external
3. Implement integration actions
4. Add to `settings.gradle.kts`: `":integrations:your-integration"`

## Structure

```
your-integration/
├── build.gradle.kts           # Depends on :modules:X and :external:Y
└── src/main/kotlin/.../
    └── actions/
        └── YourAction.kt      # Orchestration logic
```

## Key Patterns

- **Single Responsibility**: One integration per module+external pair
- **Orchestration**: Coordinate calls between module and external
- **Error Mapping**: Convert external errors to domain errors

## Example: iam-stytch

The `iam-stytch` integration connects the IAM module to Stytch auth:
- `RequestDiscovery` → Calls Stytch + creates local record
- `CreateUserAndOrg` → Uses IAM module to create entities
