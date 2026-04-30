package com.edgecat.app.conversations.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Dao
interface ConversationDao {

  @Insert(onConflict = OnConflictStrategy.ABORT)
  suspend fun insertConversation(conversation: ConversationEntity): Long

  @Query(
    "SELECT * FROM conversations WHERE message_count > 0 " +
      "ORDER BY pinned DESC, pinned_at DESC, updated_at DESC"
  )
  fun observeConversations(): Flow<List<ConversationEntity>>

  @Query("SELECT * FROM conversations WHERE id = :id LIMIT 1")
  suspend fun getConversation(id: Long): ConversationEntity?

  @Query(
    """
    UPDATE conversations
    SET title = :title,
        updated_at = :updatedAt,
        message_count = :messageCount,
        last_message_preview = :preview
    WHERE id = :id
    """
  )
  suspend fun updateConversationMeta(
    id: Long,
    title: String,
    updatedAt: Long,
    messageCount: Int,
    preview: String,
  )

  @Query("DELETE FROM conversations WHERE id = :id")
  suspend fun deleteConversation(id: Long)

  @Query("DELETE FROM conversations WHERE message_count = 0")
  suspend fun deleteEmptyConversations()

  @Query("UPDATE conversations SET pinned = :pinned, pinned_at = :pinnedAt WHERE id = :id")
  suspend fun setPinned(id: Long, pinned: Boolean, pinnedAt: Long)

  @Insert
  suspend fun insertMessage(message: MessageEntity): Long

  @Query("SELECT * FROM messages WHERE conversation_id = :conversationId ORDER BY created_at ASC")
  suspend fun getMessages(conversationId: Long): List<MessageEntity>

  @Query("SELECT COUNT(*) FROM messages WHERE conversation_id = :conversationId")
  suspend fun messageCount(conversationId: Long): Int
}
