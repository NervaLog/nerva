package dev.template.iam_stytch

import arrow.core.raise.context.either
import dev.nerva.PostgrestContainer
import dev.nerva.TestContainers
import dev.template.iam.ProviderSubject
import dev.template.iam.UserInfo
import dev.template.iam.actions.CreateUserAndOrg
import dev.template.iam.model.OrgRole
import dev.dailywombat.postgrest.Postgrest
import dev.dailywombat.utils.Email
import dev.dailywombat.utils.Slug
import io.kotest.matchers.should
import io.kotest.matchers.shouldBe
import io.kotest.matchers.shouldNotBe
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test

class IamStytchTests {

    companion object {
        @BeforeAll
        @JvmStatic
        fun before() = TestContainers.start()

        @AfterAll
        @JvmStatic
        fun after() = TestContainers.stop()
    }

    @Test
    fun `create user and org with membership works`() {
        context(Postgrest.client(PostgrestContainer.config)) {
            either {
                val user = CreateUserAndOrg(
                    provider = StytchIdentityTypes.stytch_magic_link,
                    providerSubject = ProviderSubject("stytch-A"),
                    email = Email("send@it.com"),
                    orgSlug = Slug.of("AZ")
                )
                user.email shouldBe "send@it.com"

                UserInfo.byEmail(Email("send@it.com")).should {
                    it.shouldNotBe(null)
                    it!!.email shouldBe user.email
                    it.org_membership.size shouldBe 1
                    it.org_membership[0].effectiveRole shouldBe OrgRole.owner
                }
            }
        }
    }
}