package dev.template.iam_stytch

import arrow.core.raise.context.either
import arrow.core.raise.context.withError
import dev.nerva.PostgrestContainer
import dev.nerva.TestContainers
import dev.template.iam.ProviderSubject
import dev.template.iam.UserInfo
import dev.template.iam.actions.CreateUserAndOrg
import dev.template.iam.model.OrgRole
import dev.template.iam_stytch.discovery.actions.ClaimDiscoveryRequest
import dev.template.iam_stytch.discovery.actions.ConfirmDiscoveryConsumed
import dev.template.iam_stytch.discovery.actions.CreateDiscoveryRequest
import dev.template.iam_stytch.discovery.models.DiscoveryFingerprints
import dev.dailywombat.postgrest.Postgrest
import dev.dailywombat.stytch.Pkce
import dev.dailywombat.stytch.RequestId
import dev.dailywombat.utils.Email
import dev.dailywombat.utils.Slug
import io.kotest.matchers.shouldBe
import io.kotest.matchers.shouldNotBe
import org.http4k.core.Uri
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test

/**
 * Tests the discovery request flow without Stytch:
 * 1. Create discovery request (stores PKCE, token, etc.)
 * 2. Claim the request (acquires lease)
 * 3. Create user and org (simulates what happens after Stytch auth)
 * 4. Confirm consumption (releases lease, marks consumed)
 * 5. Verify idempotency (second claim fails)
 */
class DiscoveryRoundTripTest {

    companion object {
        @BeforeAll
        @JvmStatic
        fun before() = TestContainers.start()

        @AfterAll
        @JvmStatic
        fun after() = TestContainers.stop()
    }

    @Test
    fun `discovery request can be created, claimed, and consumed`() {
        val email = Email("creator@example.com")
        val leaseOwner = "test-worker-1"

        context(Postgrest.client(PostgrestContainer.config)) {
            either<IamStytchError, Unit> {
                // 1. Create discovery request
                val verifier = Pkce.generateVerifier()
                val challenge = Pkce.CodeChallenge(verifier.value) // Simplified for test
                val token = DiscoveryRequestToken()

                val fingerprints = DiscoveryFingerprints(
                    verifier = verifier,
                    codeChallenge = challenge,
                    requestId = RequestId("stytch-request-123"),
                    token = token,
                    redirectTo = Uri.of("https://example.com/callback")
                )

                val request = CreateDiscoveryRequest(
                    email = email,
                    firstName = "Test",
                    fingerprints = fingerprints
                )

                request.email shouldBe email
                request.token shouldBe token

                // 2. Claim the request
                val claimed = ClaimDiscoveryRequest(token, leaseOwner)
                claimed.email shouldBe email
                claimed.verifier shouldBe verifier
                claimed.id shouldBe request.id

                // 3. Create user and org (simulating post-Stytch-auth)
                val userInfo = withError(IamStytchError::PostgRest) {
                    CreateUserAndOrg(
                        provider = StytchIdentityTypes.stytch_magic_link,
                        providerSubject = ProviderSubject("stytch-member-123"),
                        email = email,
                        firstName = "Test",
                        orgSlug = Slug("org-test-slug")
                    )
                }

                userInfo.email shouldBe email.value
                userInfo.org_membership.size shouldBe 1
                userInfo.org_membership[0].effectiveRole shouldBe OrgRole.owner
                userInfo.org_membership[0].orgs.slug shouldBe Slug("org-test-slug")
                userInfo.org_membership[0].orgs.name shouldBe "org-test-slug"

                // 4. Confirm consumption
                ConfirmDiscoveryConsumed(claimed.id, leaseOwner)

                // 5. Verify user exists via query
                val queried = withError(IamStytchError::PostgRest) {
                    UserInfo.byEmail(email)
                }
                queried shouldNotBe null
                queried!!.id shouldBe userInfo.id
            }.fold(
                ifLeft = { error -> throw AssertionError("Test failed with error: $error") },
                ifRight = { /* success */ }
            )
        }
    }

    @Test
    fun `second claim on same token fails after consumption`() {
        val email = Email("creator2@example.com")
        val leaseOwner = "test-worker-2"

        context(Postgrest.client(PostgrestContainer.config)) {
            either<IamStytchError, Unit> {
                val verifier = Pkce.generateVerifier()
                val challenge = Pkce.CodeChallenge(verifier.value)
                val token = DiscoveryRequestToken()

                val fingerprints = DiscoveryFingerprints(
                    verifier = verifier,
                    codeChallenge = challenge,
                    requestId = RequestId("stytch-request-456"),
                    token = token,
                    redirectTo = Uri.of("https://example.com/callback")
                )

                CreateDiscoveryRequest(email, "Test2", fingerprints)
                val claimed = ClaimDiscoveryRequest(token, leaseOwner)
                ConfirmDiscoveryConsumed(claimed.id, leaseOwner)

                // Second claim should fail - try it in a nested either
                val secondClaimResult = either<IamStytchError, ClaimDiscoveryRequest.Claimed> {
                    ClaimDiscoveryRequest(token, "another-worker")
                }

                secondClaimResult.isLeft() shouldBe true
            }.fold(
                ifLeft = { error -> throw AssertionError("Test failed with error: $error") },
                ifRight = { /* success */ }
            )
        }
    }

    @Test
    fun `idempotent user creation - same email creates same user`() {
        val email = Email("idempotent@example.com")

        context(Postgrest.client(PostgrestContainer.config)) {
            either<IamStytchError, Unit> {
                // Create user first time
                val user1 = withError(IamStytchError::PostgRest) {
                    CreateUserAndOrg(
                        provider = StytchIdentityTypes.stytch_magic_link,
                        providerSubject = ProviderSubject("stytch-member-idempotent"),
                        email = email,
                        orgSlug = Slug("org-idempotent")
                    )
                }

                // Create again with same email - should return same user
                val user2 = withError(IamStytchError::PostgRest) {
                    CreateUserAndOrg(
                        provider = StytchIdentityTypes.stytch_magic_link,
                        providerSubject = ProviderSubject("stytch-member-idempotent"),
                        email = email,
                        orgSlug = Slug("org-idempotent")
                    )
                }

                user1.id shouldBe user2.id
                user1.email shouldBe user2.email
            }.fold(
                ifLeft = { error -> throw AssertionError("Test failed with error: $error") },
                ifRight = { /* success */ }
            )
        }
    }
}
