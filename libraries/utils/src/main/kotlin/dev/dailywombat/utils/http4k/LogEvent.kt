package dev.dailywombat.utils.http4k

import org.http4k.core.Filter
import org.http4k.core.then
import org.http4k.events.AutoMarshallingEvents
import org.http4k.events.Event
import org.http4k.events.EventFilters
import org.http4k.events.then
import org.http4k.filter.HttpTransactionLabeler
import org.http4k.filter.ResponseFilters
import org.http4k.format.Jackson
import java.time.Instant

data class LogEvent(
    val path: String,
    val status: Int,
    val duration: Long,
) : Event {

    @Suppress("FunctionName")
    companion object {
        fun StructuredLoggingFilter(
            serviceName: String,
            ignorePathsStartingWith: List<String> = Http4kK8.K8ProbePaths,
            labeler: HttpTransactionLabeler = { it },
        ) = Filter { next ->
            { req ->
                when {
                    ignorePathsStartingWith.any { req.uri.path.startsWith(it) } -> next(req)
                    else -> {
                        ResponseFilters.ReportHttpTransaction(transactionLabeler = labeler) { tx ->
                            val eventFilterStack =
                                EventFilters
                                    .AddServiceName(serviceName)
                                    .then(EventFilters.AddTimestamp { Instant.now() })
                                    .then(EventFilters.AddEventName())
                                    .then(AutoMarshallingEvents(Jackson))

                            eventFilterStack.invoke(
                                LogEvent(
                                    path = tx.request.uri.path,
                                    status = tx.response.status.code,
                                    duration = tx.duration.toMillis(),
                                )
                            )
                        }.then(next)(req)
                    }
                }
            }
        }
    }
}