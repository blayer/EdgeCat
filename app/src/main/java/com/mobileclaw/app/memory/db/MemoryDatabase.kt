package com.mobileclaw.app.memory.db

import androidx.room.Database
import androidx.room.RoomDatabase

@Database(
  entities = [
    EpisodeEntity::class,
    EpisodeFts::class,
    RepairEntity::class,
    RepairFts::class,
    DeviceFactEntity::class,
    DeviceFactFts::class,
  ],
  version = 1,
  exportSchema = false,
)
abstract class MemoryDatabase : RoomDatabase() {
  abstract fun memoryDao(): MemoryDao
}
