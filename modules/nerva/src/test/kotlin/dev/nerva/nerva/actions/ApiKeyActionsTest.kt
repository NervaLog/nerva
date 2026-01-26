package dev.nerva.nerva.actions

import arrow.core.raise.either
import dev.nerva.PostgrestContainer
import dev.nerva.TestContainers
import dev.template.iam.Iam
import dev.template.iam.enums.AuthProvider
import dev.template.iam.model.OrgMembership.Companion.Role
import dev.dailywombat.postgrest.Postgrest
import dev.dailywombat.utils.Email
import dev.dailywombat.utils.Seeds.freshBase32Id
import dev.dailywombat.utils.Slug
import io.kotest.matchers.shouldBe
import io.kotest.matchers.shouldNotBe
import io.kotest.matchers.string.shouldStartWith
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.fail
import java.util.*

class ApiKeyActionsTest {

    companion object {
        private lateinit var testOrgId: UUID

        @BeforeAll
        @JvmStatic
        fun before() {
            TestContainers.start()

            // Create a test org
            context(Postgrest.client(PostgrestContainer.config)) {
                val userInfo = either {
                    Iam.createUserAndOrgWithMembership(
                        Iam.UserAndOrgSeedData(
                            provider = AuthProvider.stytch_magic_link,
                            provider_subject = Iam.IdentityProviderId("apikey-test-${freshBase32Id(8)}"),
                            email = Email("apikey-test-${freshBase32Id(8)}@nerva.dev"),
                            org_slug = Slug.of(freshBase32Id(20)),
                            role = Role.owner
                        )
                    )
                }.fold(
                    ifLeft = { throw RuntimeException("Failed to create test org: $it") },
                    ifRight = { it }
                )
                testOrgId = userInfo.org_membership.first().orgs.id
            }
        }

        @AfterAll
        @JvmStatic
        fun after() = TestContainers.stop()
    }

    @Test
    fun `CreateApiKey should create a valid API key`() {
        context(Postgrest.client(PostgrestContainer.config)) {
            val result = either {
                CreateApiKey(
                    CreateApiKeyInput(
                        orgId = testOrgId,
                        name = "Test Key",
                        description = "A test API key"
                    )
                )
            }.fold(
                ifLeft = { fail("CreateApiKey failed: $it") },
                ifRight = { it }
            )

            result.apiKey shouldStartWith "nv_"
            result.keyPrefix shouldStartWith "nv_"
            result.keyPrefix.length shouldBe 11
            result.keyId shouldNotBe null
        }
    }

    @Test
    fun `ValidateApiKey should return valid for correct key`() {
        context(Postgrest.client(PostgrestContainer.config)) {
            // Create a key
            val createResult = either {
                CreateApiKey(
                    CreateApiKeyInput(
                        orgId = testOrgId,
                        name = "Validation Test Key",
                        scopes = listOf("events:write")
                    )
                )
            }.fold(
                ifLeft = { fail("CreateApiKey failed: $it") },
                ifRight = { it }
            )

            // Validate it
            val validation = either {
                ValidateApiKey(createResult.apiKey)
            }.fold(
                ifLeft = { fail("ValidateApiKey failed: $it") },
                ifRight = { it }
            )

            validation shouldNotBe null
            when (validation) {
                is ApiKeyValidation.Valid -> {
                    validation.orgId shouldBe testOrgId
                    validation.keyId shouldBe createResult.keyId
                    validation.scopes shouldBe listOf("events:write")
                }
                is ApiKeyValidation.Invalid -> fail("Expected valid key but got: ${validation.error}")
            }
        }
    }

    @Test
    fun `ValidateApiKey should return invalid for wrong key`() {
        context(Postgrest.client(PostgrestContainer.config)) {
            val validation = either {
                ValidateApiKey("nv_invalidkeyvalue12345")
            }.fold(
                ifLeft = { fail("ValidateApiKey failed: $it") },
                ifRight = { it }
            )

            when (validation) {
                is ApiKeyValidation.Valid -> fail("Expected invalid but got valid")
                is ApiKeyValidation.Invalid -> {
                    validation.error shouldBe "key_not_found"
                }
            }
        }
    }

    @Test
    fun `ValidateApiKey should return invalid for malformed key`() {
        context(Postgrest.client(PostgrestContainer.config)) {
            val validation = either {
                ValidateApiKey("short")
            }.fold(
                ifLeft = { fail("ValidateApiKey failed: $it") },
                ifRight = { it }
            )

            when (validation) {
                is ApiKeyValidation.Valid -> fail("Expected invalid but got valid")
                is ApiKeyValidation.Invalid -> {
                    validation.error shouldBe "invalid_key_format"
                }
            }
        }
    }

    @Test
    fun `ValidateApiKey should return invalid for empty key`() {
        context(Postgrest.client(PostgrestContainer.config)) {
            val validation = either {
                ValidateApiKey("")
            }.fold(
                ifLeft = { fail("ValidateApiKey failed: $it") },
                ifRight = { it }
            )

            when (validation) {
                is ApiKeyValidation.Valid -> fail("Expected invalid but got valid")
                is ApiKeyValidation.Invalid -> {
                    validation.error shouldBe "invalid_key_format"
                }
            }
        }
    }

    @Test
    fun `CreateApiKey with scopes should preserve scopes`() {
        context(Postgrest.client(PostgrestContainer.config)) {
            val scopes = listOf("events:read", "events:write", "attention:read")

            val result = either {
                CreateApiKey(
                    CreateApiKeyInput(
                        orgId = testOrgId,
                        name = "Scoped Key",
                        scopes = scopes
                    )
                )
            }.fold(
                ifLeft = { fail("CreateApiKey failed: $it") },
                ifRight = { it }
            )

            // Validate and check scopes
            val validation = either {
                ValidateApiKey(result.apiKey)
            }.fold(
                ifLeft = { fail("ValidateApiKey failed: $it") },
                ifRight = { it }
            )

            when (validation) {
                is ApiKeyValidation.Valid -> {
                    validation.scopes shouldBe scopes
                }
                is ApiKeyValidation.Invalid -> fail("Expected valid key")
            }
        }
    }
}
