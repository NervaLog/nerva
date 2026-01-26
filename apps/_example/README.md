# Example App

This is a template for creating new applications.

## Creating a New App

1. Copy this directory: `cp -r apps/_example apps/your-app`
2. Rename package: `s/example_app/your_app/g`
3. Update `build.gradle.kts`:
   - Change main class
   - Add your dependencies
   - Update Jib registry
4. Add to `settings.gradle.kts`: `":apps:your-app"`

## Structure

```
your-app/
├── build.gradle.kts           # Deps, Jib config
└── src/main/kotlin/.../
    ├── App.kt                 # Entry point
    ├── YourAppConfig.kt       # Environment config
    └── endpoints/
        └── YourEndpoint.kt    # HTTP handlers
```

## Running

```bash
# Development
./gradlew :apps:your-app:run

# Build Docker image
./gradlew :apps:your-app:jib
```

## Environment Variables

Create `.env` in `src/main/resources/`:
```
SERVICE_PORT=8080
HEALTH_PORT=8081
POSTGREST_URL=http://localhost:3000
DB_HOST=localhost
DB_PORT=5432
DB_NAME=dev
DB_USER=postgres
DB_PASSWORD=postgres
```

## Key Patterns

- **Environment Config**: Use http4k Environment + lenses
- **K8s Server**: Built-in health checks at HEALTH_PORT
- **Structured Logging**: LogEvent filter for JSON logs
