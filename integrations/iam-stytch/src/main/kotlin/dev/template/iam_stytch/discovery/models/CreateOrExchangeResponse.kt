package dev.template.iam_stytch.discovery.models

import com.stytch.java.b2b.models.discoveryintermediatesessions.ExchangeResponse
import com.stytch.java.b2b.models.discoveryorganizations.CreateResponse
import com.stytch.java.b2b.models.mfa.MfaRequired
import com.stytch.java.b2b.models.organizations.Member
import com.stytch.java.b2b.models.organizations.Organization
import com.stytch.java.b2b.models.sessions.MemberSession
import com.stytch.java.b2b.models.sessions.PrimaryRequired
import com.stytch.java.consumer.models.devicehistory.DeviceInfo


data class CreateOrExchangeResponse(
    val requestId: String,
    val memberId: String,
    val sessionToken: String,
    val sessionJwt: String,
    val member: Member,
    val memberAuthenticated: Boolean,
    val intermediateSessionToken: String,
    val statusCode: Int,
    val memberSession: MemberSession? = null,
    val mfaRequired: MfaRequired? = null,
    val primaryRequired: PrimaryRequired? = null,
    val memberDevice: DeviceInfo? = null,
    val organization: Organization? = null,
    val organizationCreated: Boolean
) {
    companion object {
        fun fromCreate(r: CreateResponse): CreateOrExchangeResponse =
            CreateOrExchangeResponse(
                requestId = r.requestId,
                memberId = r.memberId,
                sessionToken = r.sessionToken,
                sessionJwt = r.sessionJwt,
                member = r.member,
                memberAuthenticated = r.memberAuthenticated,
                intermediateSessionToken = r.intermediateSessionToken,
                statusCode = r.statusCode,
                memberSession = r.memberSession,
                mfaRequired = r.mfaRequired,
                primaryRequired = r.primaryRequired,
                memberDevice = r.memberDevice,
                organization = r.organization,
                organizationCreated = true
            )

        fun fromExchange(r: ExchangeResponse): CreateOrExchangeResponse =
            CreateOrExchangeResponse(
                requestId = r.requestId,
                memberId = r.memberId,
                sessionToken = r.sessionToken,
                sessionJwt = r.sessionJwt,
                member = r.member,
                memberAuthenticated = r.memberAuthenticated,
                intermediateSessionToken = r.intermediateSessionToken,
                statusCode = r.statusCode,
                memberSession = r.memberSession,
                mfaRequired = r.mfaRequired,
                primaryRequired = r.primaryRequired,
                memberDevice = r.memberDevice,
                organization = r.organization,
                organizationCreated = false
            )
    }
}
