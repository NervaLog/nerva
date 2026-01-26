package dev.template.iam_stytch.discovery.actions

import arrow.core.raise.context.Raise
import arrow.core.raise.context.withError
import com.stytch.java.b2b.StytchB2BClient
import dev.template.iam_stytch.IamStytchError
import dev.dailywombat.stytch.IntermediateSessionToken
import dev.dailywombat.stytch.OrgId
import dev.dailywombat.stytch.api.Discovery

internal object ExchangeIntermediateTokenForSession {

    context(
        _: StytchB2BClient,
        _: Raise<IamStytchError>
    )
    operator fun invoke(
        token: IntermediateSessionToken,
        orgId: OrgId
    ) = withError(IamStytchError::Stytch) {
        Discovery.intermediateSessionsExchange(token, orgId)
    }
}