package dev.template.iam_stytch.discovery.flows

import arrow.core.raise.context.Raise
import com.stytch.java.b2b.StytchB2BClient
import com.stytch.java.b2b.models.magiclinksdiscovery.AuthenticateResponse
import dev.template.iam_stytch.IamStytchError
import dev.template.iam_stytch.discovery.actions.CreateStytchOrganization
import dev.template.iam_stytch.discovery.actions.ExchangeIntermediateTokenForSession
import dev.template.iam_stytch.discovery.models.CreateOrExchangeResponse
import dev.dailywombat.stytch.IntermediateSessionToken
import dev.dailywombat.stytch.OrgId

object CreateStytchOrgAndOrLogUserIn {

    context(
        _: StytchB2BClient,
        _: Raise<IamStytchError>
    )
    operator fun invoke(
        auth: AuthenticateResponse
    ): CreateOrExchangeResponse {
        val token = IntermediateSessionToken(auth.intermediateSessionToken)
        return auth.theOrg()
            ?.let {
                CreateOrExchangeResponse.fromExchange(
                    ExchangeIntermediateTokenForSession(
                        token,
                        OrgId(it.organization!!.organizationId)
                    )
                )
            }
            ?: CreateOrExchangeResponse.fromCreate(
                CreateStytchOrganization(
                    token
                )
            )
    }

    private fun AuthenticateResponse.theOrg() =
        discoveredOrganizations.firstOrNull()
}