package com.edgecat.app.data.db

import androidx.room.Database
import androidx.room.RoomDatabase
import com.edgecat.app.conversations.db.ConversationDao
import com.edgecat.app.conversations.db.ConversationEntity
import com.edgecat.app.conversations.db.MessageEntity
import com.edgecat.app.memory.db.DeviceFactEntity
import com.edgecat.app.memory.db.DeviceFactFts
import com.edgecat.app.memory.db.EpisodeEntity
import com.edgecat.app.memory.db.EpisodeFts
import com.edgecat.app.memory.db.MemoryDao
import com.edgecat.app.memory.db.RepairEntity
import com.edgecat.app.memory.db.RepairFts

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
