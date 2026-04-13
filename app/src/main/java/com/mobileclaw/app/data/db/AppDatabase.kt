package com.mobileclaw.app.data.db

import androidx.room.Database
import androidx.room.RoomDatabase
import com.mobileclaw.app.conversations.db.ConversationDao
import com.mobileclaw.app.conversations.db.ConversationEntity
import com.mobileclaw.app.conversations.db.MessageEntity
import com.mobileclaw.app.memory.db.DeviceFactEntity
import com.mobileclaw.app.memory.db.DeviceFactFts
import com.mobileclaw.app.memory.db.EpisodeEntity
import com.mobileclaw.app.memory.db.EpisodeFts
import com.mobileclaw.app.memory.db.MemoryDao
import com.mobileclaw.app.memory.db.RepairEntity
import com.mobileclaw.app.memory.db.RepairFts

@Database(
  entities = [
    EpisodeEntity::class,
    EpisodeFts::class,
    RepairEntity::class,
    RepairFts::class,
    DeviceFactEntity::class,
    DeviceFactFts::class,
    ConversationEntity::class,
    MessageEntity::class,
  ],
  version = 2,
  exportSchema = false,
)
abstract class AppDatabase : RoomDatabase() {
  abstract fun memoryDao(): MemoryDao
  abstract fun conversationDao(): ConversationDao
}
