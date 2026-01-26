package dev.dailywombat.jobs.runtime.listener

import com.impossibl.postgres.api.jdbc.PGConnection
import com.impossibl.postgres.api.jdbc.PGNotificationListener


class PGNotificationListenerSession(
    private val connectionSource: () -> PGConnection,
    private val channel: String,
    private val onClosed: () -> Unit,
    private val onNotify: () -> Unit,
) : AutoCloseable {

    private var conn: PGConnection? = null

    private val listener = object : PGNotificationListener {
        override fun notification(processId: Int, channelName: String?, payload: String) {
            when {
                channelName == null || channelName == channel -> onNotify()
            }
        }

        override fun closed() = onClosed()
    }

    fun open() {
        conn = connectionSource().apply {
            addNotificationListener(listener)
            createStatement().use { it.execute("LISTEN ${quoteIdent(channel)}") }
        }
    }

    override fun close() {
        conn?.let { c ->
            conn = null
            try {
                c.removeNotificationListener(listener)
            } catch (_: Throwable) {
            }
            try {
                c.createStatement().use { it.execute("UNLISTEN ${quoteIdent(channel)}") }
            } catch (_: Throwable) {
            }
            try {
                c.close()
            } catch (_: Throwable) {
            }
        }
    }

    private fun quoteIdent(ident: String): String {
        val escaped = ident.replace("\"", "\"\"")
        return "\"$escaped\""
    }
}
