# Main App

Primary web application for Creator Vortex serving HTML pages with Pebble templates and Tailwind CSS.

## Quick Start

```bash
# 1. Start infrastructure
cd docker-compose && docker compose up -d

# 2. Build CSS and run the app
./gradlew :apps:main:run
```

Visit `http://localhost:9000`

## Tailwind CSS

The app uses Tailwind CSS v4 with the standalone CLI (no Node.js required).

### How It Works

- **Input:** `src/main/resources/assets/css/input.css`
- **Output:** `src/main/resources/assets/css/output.css` (gitignored)
- Tailwind CLI binary is downloaded automatically to `build/tailwind/`
- CSS is compiled during `processResources` (part of build lifecycle)

### Commands

```bash
# Build CSS once (runs automatically during build)
./gradlew :apps:main:buildCss

# Watch for changes during development
./gradlew :apps:main:watchCss
```

### Customizing Styles

Tailwind v4 uses CSS-first configuration. Edit `input.css`:

```css
@import "tailwindcss";

/* Customize theme with @theme directive */
@theme {
  --color-primary: #3b82f6;
  --color-accent: #10b981;
}

/* Add custom components */
@layer components {
  .btn {
    @apply px-4 py-2 rounded-lg font-medium;
  }
}
```

See: [Tailwind v4 Theme Docs](https://tailwindcss.com/docs/theme)

## Pebble Templates

Templates use http4k's Pebble integration.

### Structure

```
src/main/
├── kotlin/me/rename/
│   ├── views/           # ViewModel classes
│   │   └── LoginPage.kt
│   └── endpoints/       # Route handlers
│       └── Login.kt
└── resources/views/me/rename/views/
    └── LoginPage.peb    # Pebble templates
```

### Convention

- Template path mirrors ViewModel's fully qualified class name
- `me.rename.views.LoginPage` → `views/me/rename/views/LoginPage.peb`
- Access model properties with `{{ model.propertyName }}`

### Example

```kotlin
// ViewModel
data class LoginPage(val email: String? = null) : ViewModel

// Handler
fun Login(renderer: TemplateRenderer): RoutingHttpHandler {
    val viewLens = Body.viewModel(renderer, ContentType.TEXT_HTML).toLens()
    return routes(
        "/" bind GET to { Response(OK).with(viewLens of LoginPage()) }
    )
}
```

```html
<!-- Template -->
<input type="email" value="{{ model.email | default('') }}"/>
```

## Routes

| Path | Method | Description |
|------|--------|-------------|
| `/` | GET | Home page |
| `/login` | GET | Login form |
| `/login` | POST | Submit email for magic link |
| `/assets/*` | GET | Static files (CSS, JS, images) |

## Configuration

Environment variables in `src/main/resources/.env`:

| Variable | Description |
|----------|-------------|
| `SERVICE_PORT` | HTTP server port (default: 9000) |
| `HEALTH_PORT` | Health check port (default: 9001) |
| `FLYWAY_*` | Database migration settings |
