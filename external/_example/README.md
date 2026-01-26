# Example External SDK Wrapper

This is a template for wrapping third-party SDK integrations.

## Creating a New SDK Wrapper

1. Copy this directory: `cp -r external/_example external/your-service`
2. Rename package: `s/example_sdk/your_service/g`
3. Add SDK dependency to `build.gradle.kts`
4. Implement config, client, and error types
5. Add to `settings.gradle.kts`: `":external:your-service"`

## Structure

```
your-service/
├── build.gradle.kts
└── src/main/kotlin/.../your_service/
    ├── YourServiceConfig.kt   # Environment-based config
    ├── YourServiceClient.kt   # Client wrapper with lazy init
    └── YourServiceError.kt    # Typed error ADT
```

## Key Patterns

- **Config**: Load from environment variables, never hardcode
- **Client**: Lazy initialization, cache instances
- **Errors**: Sealed interface for typed error handling

## Environment Variables

Add to `.env`:
```
YOUR_SERVICE_API_KEY=xxx
YOUR_SERVICE_BASE_URL=https://api.example.com  # optional
```
