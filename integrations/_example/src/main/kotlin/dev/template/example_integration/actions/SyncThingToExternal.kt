package dev.template.example_integration.actions

import arrow.core.raise.context.Raise
import dev.template.example.model.Thing
import dev.template.example_sdk.ExampleClientInstance
import dev.template.example_sdk.ExampleError

/**
 * Example integration action - orchestrates a module + external service.
 *
 * Integrations:
 * - Connect domain modules to external services
 * - Handle the mapping between internal and external models
 * - Coordinate multi-step operations
 */
object SyncThingToExternal {

    context(
        client: ExampleClientInstance,
        _: Raise<ExampleError>
    )
    operator fun invoke(thing: Thing): String {
        // Call external service with domain data
        val result = client.doSomething(thing.name)

        return result.getOrElse {
            raise(ExampleError.NetworkError("Failed to sync: ${it.message}", it))
        }
    }
}
