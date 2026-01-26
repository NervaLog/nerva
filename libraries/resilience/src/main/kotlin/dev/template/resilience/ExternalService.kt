package dev.template.resilience

/**
 * Enumeration of external services that require resilience protection.
 *
 * Each service has its own circuit breaker to prevent cascading failures
 * and allow independent recovery.
 */
enum class ExternalService {
    /** Google Gemini AI API for video summarization */
    GEMINI,

    /** YouTube oEmbed API for video metadata */
    YOUTUBE,

    /** Stytch authentication service */
    STYTCH,

    /** Stripe payment processing */
    STRIPE
}
