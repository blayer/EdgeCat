package com.mobileclaw.app.conversations

import com.mobileclaw.app.conversations.db.ConversationDao
import com.mobileclaw.app.conversations.db.ConversationEntity
import com.mobileclaw.app.conversations.db.MessageEntity
import kotlinx.coroutines.flow.Flow

interface ConversationRepository {
  fun observeConversations(): Flow<List<ConversationEntity>>
  suspend fun getConversation(id: Long): ConversationEntity?
  suspend fun createConversation(): Long
  suspend fun deleteConversation(id: Long)
  suspend fun setPinned(id: Long, pinned: Boolean)
  suspend fun getMessages(conversationId: Long): List<MessageEntity>
  /** Appends a message. Returns true if persisted; false if role is not user/assistant. */
  suspend fun appendMessage(conversationId: Long, role: String, content: String): Boolean
}

const val ROLE_USER = "user"
const val ROLE_ASSISTANT = "assistant"

private const val TITLE_MAX = 40
private const val PREVIEW_MAX = 80

class DefaultConversationRepository(
  private val dao: ConversationDao,
) : ConversationRepository {

  override fun observeConversations(): Flow<List<ConversationEntity>> = dao.observeConversations()

  override suspend fun getConversation(id: Long): ConversationEntity? = dao.getConversation(id)

  override suspend fun createConversation(): Long {
    val now = System.currentTimeMillis()
    return dao.insertConversation(
      ConversationEntity(
        title = "",
        createdAt = now,
        updatedAt = now,
        messageCount = 0,
        lastMessagePreview = "",
      )
    )
  }

  override suspend fun deleteConversation(id: Long) {
    dao.deleteConversation(id)
  }

  override suspend fun setPinned(id: Long, pinned: Boolean) {
    dao.setPinned(id, pinned, if (pinned) System.currentTimeMillis() else 0L)
  }

  override suspend fun getMessages(conversationId: Long): List<MessageEntity> =
    dao.getMessages(conversationId)

  override suspend fun appendMessage(
    conversationId: Long,
    role: String,
    content: String,
  ): Boolean {
    if (role != ROLE_USER && role != ROLE_ASSISTANT) return false
    if (content.isBlank()) return false
    val existing = dao.getConversation(conversationId) ?: return false
    val now = System.currentTimeMillis()
    dao.insertMessage(
      MessageEntity(
        conversationId = conversationId,
        role = role,
        createdAt = now,
        content = content,
      )
    )
    val newCount = existing.messageCount + 1
    val newTitle =
      if (existing.title.isBlank() && role == ROLE_USER) deriveTitle(content) else existing.title
    val preview = content.trim().take(PREVIEW_MAX)
    dao.updateConversationMeta(
      id = conversationId,
      title = newTitle,
      updatedAt = now,
      messageCount = newCount,
      preview = preview,
    )
    return true
  }

  private fun deriveTitle(content: String): String {
    val trimmed = content.trim().replace(Regex("\\s+"), " ")
    if (trimmed.length <= TITLE_MAX) return trimmed
    val cut = trimmed.take(TITLE_MAX)
    val lastSpace = cut.lastIndexOf(' ')
    return if (lastSpace in 20 until TITLE_MAX) cut.take(lastSpace) else cut
  }
}
