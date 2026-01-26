package dev.template.example_sdk

/**
 * Example error types for SDK operations.
 *
 * Pattern: Sealed interface with specific error types.
 * This enables typed error handling with Arrow's Raise.
 */
sealed interface ExampleError {
    val message: String

    data class NetworkError(override val message: String, val cause: Throwable? = null) : ExampleError
    data class AuthError(override val message: String) : ExampleError
    data class NotFoundError(override val message: String) : ExampleError
    data class UnknownError(override val message: String, val cause: Throwable? = null) : ExampleError
}
