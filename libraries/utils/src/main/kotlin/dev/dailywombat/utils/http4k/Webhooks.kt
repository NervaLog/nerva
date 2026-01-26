package dev.dailywombat.utils.http4k

import org.http4k.filter.HttpTransactionLabeler

object Webhooks {
    const val XWebhookStatus = "X-Webhook-Status"
    const val InvalidFormat = "Webhook-Status"
    const val InternalError = "Internal-Error"

    /**
     * Webhooks always return 200 OK so the other side doesn't replay.
     * However we still want to know when things fail.
     * By internal convention, we do it with a response header, as per below.
     */
    val WebhookInternalErrorLabeler: HttpTransactionLabeler = {
        when (it.response.header(XWebhookStatus)) {
            InternalError -> it.label("internal-error", "true")
            else -> it
        }
    }
}