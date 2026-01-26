package dev.template.iam

import arrow.core.raise.context.either
import dev.nerva.PostgrestContainer
import dev.nerva.TestContainers
import dev.template.iam.model.OrgMembership.Companion.Role
import dev.dailywombat.postgrest.Postgrest
import dev.dailywombat.utils.Email
import dev.dailywombat.utils.Seeds.freshBase32Id
import dev.dailywombat.utils.Slug
import io.kotest.matchers.shouldBe
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test

class IamTests {

    companion object {
        @BeforeAll
        @JvmStatic
        fun before() {
            TestContainers.start()
        }

        @AfterAll
        @JvmStatic
        fun after() = TestContainers.stop()
    }

    enum class TestIdentityType {
        test_magic_link
    }

    @Test
    fun `Test Create User and Solo Org`() {
        either {
            context(Postgrest.client(PostgrestContainer.config)) {
                val userInfo = Iam.createUserAndOrgWithMembership(
                    Iam.UserAndOrgSeedData(
                        provider = TestIdentityType.test_magic_link,
                        provider_subject = Iam.IdentityProviderId("Sam-The-Wombat"),
                        email = Email("topwombat@nerva.dev"),
                        org_slug = Slug.of(freshBase32Id(20)),
                        role = Role.owner
                    )
                )
                userInfo.email shouldBe Email("topwombat@nerva.dev")
            }
        }
    }
}