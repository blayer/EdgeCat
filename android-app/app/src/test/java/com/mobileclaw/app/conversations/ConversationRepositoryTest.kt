package com.mobileclaw.app.conversations

import com.mobileclaw.app.conversations.db.ConversationDao
import com.mobileclaw.app.conversations.db.ConversationEntity
import com.mobileclaw.app.conversations.db.MessageEntity
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class ConversationRepositoryTest {

  private lateinit var dao: FakeConversationDao
  private lateinit var repo: DefaultConversationRepository

  @Before
  fun setup() {
    dao = FakeConversationDao()
    repo = DefaultConversationRepository(dao)
  }

  @Test
  fun `createConversation returns id and stores empty record`() = runTest {
    val id = repo.createConversation()
    assertTrue(id > 0L)
    val stored = repo.getConversation(id)!!
    assertEquals("", stored.title)
    assertEquals(0, stored.messageCount)
  }

  @Test
  fun `appendMessage rejects invalid role`() = runTest {
    val id = repo.createConversation()
    val ok = repo.appendMessage(id, "system", "ignored")
    assertFalse(ok)
    assertEquals(0, dao.messages.size)
  }

  @Test
  fun `appendMessage rejects blank content`() = runTest {
    val id = repo.createConversation()
    val ok = repo.appendMessage(id, ROLE_USER, "   ")
    assertFalse(ok)
    assertEquals(0, dao.messages.size)
  }

  @Test
  fun `appendMessage persists user then assistant, updates meta`() = runTest {
    val id = repo.createConversation()

    assertTrue(repo.appendMessage(id, ROLE_USER, "What's the weather in Tokyo tomorrow?"))
    assertTrue(repo.appendMessage(id, ROLE_ASSISTANT, "Sunny, 22°C. Bring light layers."))

    val conv = repo.getConversation(id)!!
    assertEquals(2, conv.messageCount)
    assertEquals("What's the weather in Tokyo tomorrow?", conv.title)
    assertTrue(conv.lastMessagePreview.startsWith("Sunny, 22"))

    val messages = repo.getMessages(id)
    assertEquals(2, messages.size)
    assertEquals(ROLE_USER, messages[0].role)
    assertEquals(ROLE_ASSISTANT, messages[1].role)
  }

  @Test
  fun `deriveTitle truncates long user messages at word boundary`() = runTest {
    val id = repo.createConversation()
    val longText =
      "Please tell me everything you know about quantum chromodynamics and the standard model"
    repo.appendMessage(id, ROLE_USER, longText)
    val conv = repo.getConversation(id)!!
    assertTrue("title should fit within ~40 chars, got: ${conv.title}", conv.title.length <= 40)
    assertFalse(conv.title.endsWith(" "))
  }

  @Test
  fun `appendMessage on unknown conversation id returns false`() = runTest {
    val ok = repo.appendMessage(999L, ROLE_USER, "hi")
    assertFalse(ok)
  }

  @Test
  fun `createConversation reaps stale empty conversations`() = runTest {
    val empty1 = repo.createConversation()
    val empty2 = repo.createConversation() // this reaps empty1
    // empty1 should be gone, empty2 is new (also empty but just created)
    assertEquals(null, repo.getConversation(empty1))
    assertTrue(repo.getConversation(empty2) != null)
  }

  @Test
  fun `createConversation keeps conversations with messages`() = runTest {
    val id = repo.createConversation()
    repo.appendMessage(id, ROLE_USER, "hello")
    val empty = repo.createConversation() // reaps empties but id has messages
    assertTrue(repo.getConversation(id) != null)
    assertTrue(repo.getConversation(empty) != null)
  }

  @Test
  fun `setPinned pins and unpins conversation`() = runTest {
    val id = repo.createConversation()
    repo.appendMessage(id, ROLE_USER, "test")
    repo.setPinned(id, true)
    assertTrue(repo.getConversation(id)!!.pinned)
    repo.setPinned(id, false)
    assertFalse(repo.getConversation(id)!!.pinned)
  }

  @Test
  fun `assistant-first message does not set title, user message later does`() = runTest {
    val id = repo.createConversation()
    repo.appendMessage(id, ROLE_ASSISTANT, "Hello")
    assertEquals("", repo.getConversation(id)!!.title)
    repo.appendMessage(id, ROLE_USER, "Hi there")
    assertEquals("Hi there", repo.getConversation(id)!!.title)
  }
}

private class FakeConversationDao : ConversationDao {
  val conversations = mutableListOf<ConversationEntity>()
  val messages = mutableListOf<MessageEntity>()
  private var nextConvId = 1L
  private var nextMsgId = 1L

  override suspend fun insertConversation(conversation: ConversationEntity): Long {
    val assignedId = nextConvId++
    conversations.add(conversation.copy(id = assignedId))
    return assignedId
  }

  override fun observeConversations(): Flow<List<ConversationEntity>> =
    flowOf(conversations.sortedByDescending { it.updatedAt })

  override suspend fun getConversation(id: Long): ConversationEntity? =
    conversations.firstOrNull { it.id == id }

  override suspend fun updateConversationMeta(
    id: Long,
    title: String,
    updatedAt: Long,
    messageCount: Int,
    preview: String,
  ) {
    val idx = conversations.indexOfFirst { it.id == id }
    if (idx >= 0) {
      conversations[idx] = conversations[idx].copy(
        title = title,
        updatedAt = updatedAt,
        messageCount = messageCount,
        lastMessagePreview = preview,
      )
    }
  }

  override suspend fun deleteConversation(id: Long) {
    conversations.removeAll { it.id == id }
    messages.removeAll { it.conversationId == id }
  }

  override suspend fun deleteEmptyConversations() {
    conversations.removeAll { it.messageCount == 0 }
  }

  override suspend fun setPinned(id: Long, pinned: Boolean, pinnedAt: Long) {
    val idx = conversations.indexOfFirst { it.id == id }
    if (idx >= 0) {
      conversations[idx] = conversations[idx].copy(pinned = pinned, pinnedAt = pinnedAt)
    }
  }

  override suspend fun insertMessage(message: MessageEntity): Long {
    val assignedId = nextMsgId++
    messages.add(message.copy(id = assignedId))
    return assignedId
  }

  override suspend fun getMessages(conversationId: Long): List<MessageEntity> =
    messages.filter { it.conversationId == conversationId }.sortedBy { it.createdAt }

  override suspend fun messageCount(conversationId: Long): Int =
    messages.count { it.conversationId == conversationId }
}
