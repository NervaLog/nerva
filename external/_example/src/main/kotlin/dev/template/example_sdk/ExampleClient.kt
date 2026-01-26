package dev.template.example_sdk

/**
 * Example SDK client wrapper.
 *
 * Pattern:
 * 1. Lazy initialization (don't create client until needed)
 * 2. Single instance per config
 * 3. Expose typed methods that wrap SDK calls
 */
object ExampleClient {

    /**
     * Create or retrieve a cached client instance.
     */
    fun client(config: ExampleConfig): ExampleClientInstance {
        // In a real implementation, you might cache instances by config
        return ExampleClientInstance(config)
    }
}

/**
 * Wrapper around the actual SDK client.
 */
class ExampleClientInstance(
    private val config: ExampleConfig
) {
    // Initialize the actual SDK client lazily
    // private val sdk by lazy { ExternalSdk(config.apiKey) }

    /**
     * Example method wrapping an SDK call.
     */
    fun doSomething(input: String): Result<String> {
        return runCatching {
            // sdk.someMethod(input)
            "Result for: $input"
        }
    }
}
