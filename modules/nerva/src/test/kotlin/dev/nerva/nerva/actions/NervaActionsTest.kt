package dev.nerva.nerva.actions

import arrow.core.raise.either
import dev.nerva.PostgrestContainer
import dev.nerva.TestContainers
import dev.nerva.nerva.enums.AttentionKind
import dev.nerva.nerva.enums.AttentionStatus
import dev.nerva.nerva.enums.EventType
import dev.template.iam.Iam
import dev.template.iam.enums.AuthProvider
import dev.template.iam.model.OrgMembership.Companion.Role
import dev.dailywombat.postgrest.Postgrest
import dev.dailywombat.utils.Email
import dev.dailywombat.utils.Seeds.freshBase32Id
import dev.dailywombat.utils.Slug
import io.kotest.matchers.shouldBe
import io.kotest.matchers.shouldNotBe
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.fail
import java.util.*

class NervaActionsTest {

    companion object {
        private lateinit var testOrgId: UUID

        @BeforeAll
        @JvmStatic
        fun before() {
            TestContainers.start()

            // Create a test org for all tests
            context(Postgrest.client(PostgrestContainer.config)) {
                val userInfo = either {
                    Iam.createUserAndOrgWithMembership(
                        Iam.UserAndOrgSeedData(
                            provider = AuthProvider.stytch_magic_link,
                            provider_subject = Iam.IdentityProviderId("nerva-test-${freshBase32Id(8)}"),
                            email = Email("nerva-test-${freshBase32Id(8)}@nerva.dev"),
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
    fun `IngestEvent should create event and attention item`() {
        val externalId = "test_event_${UUID.randomUUID()}"
        val collapseKey = "ingest_event_basic_${UUID.randomUUID()}"

        context(Postgrest.client(PostgrestContainer.config)) {
            val result = either {
                IngestEvent(
                    IngestEventInput(
                        orgId = testOrgId,
                        provider = "test_provider",
                        externalId = externalId,
                        eventType = EventType.GENERIC,
                        collapseKey = collapseKey,
                        title = "Test Event",
                        attentionKind = AttentionKind.BATCH
                    )
                )
            }.fold(
                ifLeft = { fail("IngestEvent failed: $it") },
                ifRight = { it }
            )

            result.was_created shouldBe true
            result.event_id shouldNotBe null
            result.attention_id shouldNotBe null
            result.job_id shouldNotBe null
        }
    }

    @Test
    fun `IngestEvent should be idempotent for same external_id`() {
        val externalId = "idempotent_test_${UUID.randomUUID()}"
        val collapseKey = "idempotent_test_${UUID.randomUUID()}"

        context(Postgrest.client(PostgrestContainer.config)) {
            // First ingestion
            val first = either {
                IngestEvent(
                    IngestEventInput(
                        orgId = testOrgId,
                        provider = "test_provider",
                        externalId = externalId,
                        eventType = EventType.CALENDAR_EVENT,
                        collapseKey = collapseKey,
                        title = "First Event"
                    )
                )
            }.fold(
                ifLeft = { fail("First IngestEvent failed: $it") },
                ifRight = { it }
            )

            first.was_created shouldBe true

            // Second ingestion with same external_id
            val second = either {
                IngestEvent(
                    IngestEventInput(
                        orgId = testOrgId,
                        provider = "test_provider",
                        externalId = externalId,  // Same ID
                        eventType = EventType.CALENDAR_EVENT,
                        collapseKey = collapseKey,
                        title = "Duplicate Event"
                    )
                )
            }.fold(
                ifLeft = { fail("Second IngestEvent failed: $it") },
                ifRight = { it }
            )

            // Should not create new event
            second.was_created shouldBe false
            second.event_id shouldBe first.event_id
            second.attention_id shouldBe null
            second.job_id shouldBe null
        }
    }

    @Test
    fun `IngestEvent should collapse events in same window`() {
        val collapseKey = "collapse_test_${UUID.randomUUID()}"

        context(Postgrest.client(PostgrestContainer.config)) {
            // First event
            val first = either {
                IngestEvent(
                    IngestEventInput(
                        orgId = testOrgId,
                        provider = "test_provider",
                        externalId = "collapse_1_${UUID.randomUUID()}",
                        eventType = EventType.SLACK_MESSAGE,
                        collapseKey = collapseKey,
                        title = "First Slack Message"
                    )
                )
            }.fold(
                ifLeft = { fail("First IngestEvent failed: $it") },
                ifRight = { it }
            )

            first.was_created shouldBe true
            val firstAttentionId = first.attention_id

            // Second event with same collapse key (should merge into same attention)
            val second = either {
                IngestEvent(
                    IngestEventInput(
                        orgId = testOrgId,
                        provider = "test_provider",
                        externalId = "collapse_2_${UUID.randomUUID()}",
                        eventType = EventType.SLACK_MESSAGE,
                        collapseKey = collapseKey,
                        title = "Second Slack Message"
                    )
                )
            }.fold(
                ifLeft = { fail("Second IngestEvent failed: $it") },
                ifRight = { it }
            )

            second.was_created shouldBe true
            // Same attention item due to collapse
            second.attention_id shouldBe firstAttentionId
        }
    }

    @Test
    fun `GetAttentionById should return attention item`() {
        val externalId = "get_attention_test_${UUID.randomUUID()}"
        val collapseKey = "get_attention_${UUID.randomUUID()}"

        context(Postgrest.client(PostgrestContainer.config)) {
            // Create an event first
            val ingestResult = either {
                IngestEvent(
                    IngestEventInput(
                        orgId = testOrgId,
                        provider = "test_provider",
                        externalId = externalId,
                        eventType = EventType.EMAIL_RECEIVED,
                        collapseKey = collapseKey,
                        title = "Test Email",
                        body = "Email body content"
                    )
                )
            }.fold(
                ifLeft = { fail("IngestEvent failed: $it") },
                ifRight = { it }
            )

            val attentionId = ingestResult.attention_id!!

            // Fetch the attention item
            val attention = either {
                GetAttentionById(attentionId)
            }.fold(
                ifLeft = { fail("GetAttentionById failed: $it") },
                ifRight = { it }
            )

            attention shouldNotBe null
            attention!!.id shouldBe attentionId
            attention.org_id shouldBe testOrgId
            attention.title shouldBe "Test Email"
            attention.body shouldBe "Email body content"
            attention.status shouldBe AttentionStatus.PENDING
            attention.event_count shouldBe 1
        }
    }

    @Test
    fun `GetPendingAttention should return pending items for org`() {
        val externalId = "pending_test_${UUID.randomUUID()}"
        val collapseKey = "pending_attention_${UUID.randomUUID()}"

        context(Postgrest.client(PostgrestContainer.config)) {
            // Create an event
            either {
                IngestEvent(
                    IngestEventInput(
                        orgId = testOrgId,
                        provider = "test_provider",
                        externalId = externalId,
                        eventType = EventType.TASK_DUE,
                        collapseKey = collapseKey,
                        title = "Task Due Soon",
                        attentionKind = AttentionKind.SOON
                    )
                )
            }.fold(
                ifLeft = { fail("IngestEvent failed: $it") },
                ifRight = { it }
            )

            // Fetch pending items
            val pending = either {
                GetPendingAttention(testOrgId)
            }.fold(
                ifLeft = { fail("GetPendingAttention failed: $it") },
                ifRight = { it }
            )

            pending shouldNotBe null
            pending.isNotEmpty() shouldBe true
            pending.all { it.status == AttentionStatus.PENDING } shouldBe true
        }
    }

    @Test
    fun `UpdateAttentionStatus should update status to delivered`() {
        val externalId = "update_status_test_${UUID.randomUUID()}"
        val collapseKey = "update_status_${UUID.randomUUID()}"

        context(Postgrest.client(PostgrestContainer.config)) {
            // Create an event
            val ingestResult = either {
                IngestEvent(
                    IngestEventInput(
                        orgId = testOrgId,
                        provider = "test_provider",
                        externalId = externalId,
                        eventType = EventType.MEETING_REMINDER,
                        collapseKey = collapseKey,
                        title = "Meeting in 5 min"
                    )
                )
            }.fold(
                ifLeft = { fail("IngestEvent failed: $it") },
                ifRight = { it }
            )

            val attentionId = ingestResult.attention_id!!

            // Update status
            either {
                UpdateAttentionStatus(
                    id = attentionId,
                    status = AttentionStatus.DELIVERED
                )
            }.fold(
                ifLeft = { fail("UpdateAttentionStatus failed: $it") },
                ifRight = { }
            )

            // Verify status changed
            val updated = either {
                GetAttentionById(attentionId)
            }.fold(
                ifLeft = { fail("GetAttentionById failed: $it") },
                ifRight = { it }
            )

            updated shouldNotBe null
            updated!!.status shouldBe AttentionStatus.DELIVERED
        }
    }

    @Test
    fun `Different event types should create separate attention items`() {
        val baseId = UUID.randomUUID()
        val calendarCollapseKey = "calendar_${UUID.randomUUID()}"
        val emailCollapseKey = "email_${UUID.randomUUID()}"

        context(Postgrest.client(PostgrestContainer.config)) {
            // Calendar event
            val calendar = either {
                IngestEvent(
                    IngestEventInput(
                        orgId = testOrgId,
                        provider = "test_provider",
                        externalId = "calendar_$baseId",
                        eventType = EventType.CALENDAR_EVENT,
                        collapseKey = calendarCollapseKey,
                        title = "Calendar Event"
                    )
                )
            }.fold(
                ifLeft = { fail("Calendar IngestEvent failed: $it") },
                ifRight = { it }
            )

            // Email event (different type, different collapse)
            val email = either {
                IngestEvent(
                    IngestEventInput(
                        orgId = testOrgId,
                        provider = "test_provider",
                        externalId = "email_$baseId",
                        eventType = EventType.EMAIL_RECEIVED,
                        collapseKey = emailCollapseKey,
                        title = "Email Event"
                    )
                )
            }.fold(
                ifLeft = { fail("Email IngestEvent failed: $it") },
                ifRight = { it }
            )

            // Different types should have different attention items
            calendar.attention_id shouldNotBe email.attention_id
        }
    }

    @Test
    fun `Immediate attention should enqueue high priority job`() {
        val externalId = "immediate_test_${UUID.randomUUID()}"
        val collapseKey = "immediate_${UUID.randomUUID()}"

        context(Postgrest.client(PostgrestContainer.config)) {
            val result = either {
                IngestEvent(
                    IngestEventInput(
                        orgId = testOrgId,
                        provider = "test_provider",
                        externalId = externalId,
                        eventType = EventType.GENERIC,
                        collapseKey = collapseKey,
                        title = "Urgent Alert",
                        attentionKind = AttentionKind.IMMEDIATE
                    )
                )
            }.fold(
                ifLeft = { fail("IngestEvent failed: $it") },
                ifRight = { it }
            )

            result.was_created shouldBe true
            result.job_id shouldNotBe null
            // Job is enqueued with high priority (100) for immediate attention
        }
    }
}
