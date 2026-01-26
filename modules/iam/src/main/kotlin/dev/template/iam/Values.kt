package dev.template.iam

import java.util.*

/**
 * @param value - the provider's ID for a user. E.g. in Stytch's case, member id.
 */
@JvmInline
value class ProviderSubject(val value: String)

@JvmInline
value class OrgId(val value: UUID)

@JvmInline
value class OrgSlug(val value: String)