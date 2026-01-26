package dev.template.iam_stytch

import dev.dailywombat.flyway.modules.ModuleSchema
import dev.dailywombat.flyway.modules.Entity.Companion.errorCode
import dev.dailywombat.flyway.modules.Entity.Companion.storedFunc
import dev.dailywombat.flyway.modules.Entity.Companion.table

object IamStytchSchema : ModuleSchema() {
    override val name = "iam_stytch"

    val DiscoveryRequests = table("discovery_requests")

    val ClaimDiscoveryRequest = storedFunc("claim_discovery_request")
    val ConfirmDiscoveryConsumed = storedFunc("confirm_discovery_consumed")
    val CleanupDiscoveryRequests = storedFunc("cleanup_discovery_requests")

    val RequestAlreadyConsumed = errorCode(
        "IS001",
        description = "Request could not be consumed " +
                "(missing, expired, not leased, lease expired, or already consumed)."
    )
}