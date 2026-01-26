package dev.template.resilience

import arrow.core.raise.context.either
import io.kotest.assertions.throwables.shouldThrow
import io.kotest.matchers.shouldBe
import io.kotest.matchers.types.shouldBeInstanceOf
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Test
import java.util.concurrent.atomic.AtomicInteger

// Test error type for Raise tests
private sealed interface TestError {
    data class ApiError(val message: String) : TestError
}

class ResilienceTest {

    @AfterEach
    fun cleanup() {
        Resilience.resetAllCircuitBreakers()
    }

    @Test
    fun `successful call returns result without retry`() {
        val callCount = AtomicInteger(0)

        val result = resilientCall(ExternalService.YOUTUBE) {
            callCount.incrementAndGet()
            "success"
        }

        result.isRight() shouldBe true
        result.getOrNull() shouldBe "success"
        callCount.get() shouldBe 1
    }

    @Test
    fun `retries on transient failure then succeeds`() {
        val callCount = AtomicInteger(0)

        val result = resilientCall(ExternalService.YOUTUBE) {
            val count = callCount.incrementAndGet()
            if (count < 3) {
                throw RuntimeException("Transient failure #$count")
            }
            "success after retries"
        }

        result.isRight() shouldBe true
        result.getOrNull() shouldBe "success after retries"
        callCount.get() shouldBe 3
    }

    @Test
    fun `returns failure after exhausting retries`() {
        val callCount = AtomicInteger(0)

        val result = resilientCall(ExternalService.YOUTUBE) {
            callCount.incrementAndGet()
            throw RuntimeException("Persistent failure")
        }

        result.isLeft() shouldBe true
        // YouTube config has maxRetries = 3, so 1 initial + 3 retries = 4 calls
        callCount.get() shouldBe 4
    }

    @Test
    fun `circuit breaker opens after repeated failures`() = runBlocking {
        val callCount = AtomicInteger(0)
        val service = ExternalService.YOUTUBE // maxFailures = 5

        // Exhaust the circuit breaker with failures
        // Each call will retry 3 times (initial + 3 retries = 4), and we need 5 failures to open
        repeat(6) {
            resilientCall(service) {
                callCount.incrementAndGet()
                throw RuntimeException("Failure to open circuit")
            }
        }

        // Circuit should now be open - next call should fail fast
        val fastFailCount = callCount.get()

        val result = resilientCall(service) {
            callCount.incrementAndGet()
            "should not reach here"
        }

        result.isLeft() shouldBe true
        result.leftOrNull().shouldBeInstanceOf<CircuitBreakerOpenException>()
        // Call count should not have increased (circuit rejected the call)
        callCount.get() shouldBe fastFailCount
    }

    @Test
    fun `resilientCallOrRaise raises on failure`() {
        val result = either<TestError, String> {
            resilientCallOrRaise(
                service = ExternalService.YOUTUBE,
                onError = { e -> TestError.ApiError(e.message ?: "unknown") }
            ) {
                throw RuntimeException("API failed")
            }
        }

        result.isLeft() shouldBe true
        result.leftOrNull().shouldBeInstanceOf<TestError.ApiError>()
    }

    @Test
    fun `resilientCallOrRaise returns value on success`() {
        val result = either<TestError, String> {
            resilientCallOrRaise(
                service = ExternalService.YOUTUBE,
                onError = { e -> TestError.ApiError(e.message ?: "unknown") }
            ) {
                "success"
            }
        }

        result.isRight() shouldBe true
        result.getOrNull() shouldBe "success"
    }

    @Test
    fun `different services have independent circuit breakers`() = runBlocking {
        val geminiCalls = AtomicInteger(0)
        val youtubeCalls = AtomicInteger(0)

        // Break the Gemini circuit (maxFailures = 3)
        // Each call has maxRetries = 2 (initial + 2 retries = 3 calls per attempt)
        repeat(4) {
            resilientCall(ExternalService.GEMINI) {
                geminiCalls.incrementAndGet()
                throw RuntimeException("Gemini down")
            }
        }

        // YouTube should still work
        val youtubeResult = resilientCall(ExternalService.YOUTUBE) {
            youtubeCalls.incrementAndGet()
            "youtube works"
        }

        youtubeResult.isRight() shouldBe true
        youtubeResult.getOrNull() shouldBe "youtube works"

        // Gemini should fail fast
        val geminiCallsBeforeFastFail = geminiCalls.get()
        val geminiResult = resilientCall(ExternalService.GEMINI) {
            geminiCalls.incrementAndGet()
            "should not reach"
        }

        geminiResult.isLeft() shouldBe true
        geminiResult.leftOrNull().shouldBeInstanceOf<CircuitBreakerOpenException>()
        geminiCalls.get() shouldBe geminiCallsBeforeFastFail
    }

    @Test
    fun `mapError transforms exception type`() {
        data class CustomError(val reason: String)

        val result = resilientCall(ExternalService.YOUTUBE) {
            throw IllegalArgumentException("bad input")
        }.mapError { CustomError(it.message ?: "unknown") }

        result.isLeft() shouldBe true
        result.leftOrNull() shouldBe CustomError("bad input")
    }
}
