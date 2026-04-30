package com.edgecat.app.conversations.db

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(
  tableName = "conversations",
  indices = [Index(value = ["updated_at"])],
)
data class ConversationEntity(
  @PrimaryKey(autoGenerate = true) val id: Long = 0L,
  val title: String,
  @ColumnInfo(name = "created_at") val createdAt: Long,
  @ColumnInfo(name = "updated_at") val updatedAt: Long,
  @ColumnInfo(name = "message_count") val messageCount: Int,
  @ColumnInfo(name = "last_message_preview") val lastMessagePreview: String,
  @ColumnInfo(name = "pinned", defaultValue = "0") val pinned: Boolean = false,
  @ColumnInfo(name = "pinned_at", defaultValue = "0") val pinnedAt: Long = 0L,
)

@Entity(
  tableName = "messages",
  foreignKeys = [
    ForeignKey(
      entity = ConversationEntity::class,
      parentColumns = ["id"],
      childColumns = ["conversation_id"],
      onDelete = ForeignKey.CASCADE,
    )
  ],
  indices = [Index(value = ["conversation_id", "created_at"])],
)
data class MessageEntity(
  @PrimaryKey(autoGenerate = true) val id: Long = 0L,
  @ColumnInfo(name = "conversation_id") val conversationId: Long,
  val role: String, // "user" or "assistant"
  @ColumnInfo(name = "created_at") val createdAt: Long,
  val content: String,
)
