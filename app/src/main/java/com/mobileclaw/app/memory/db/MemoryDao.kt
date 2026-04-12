package com.mobileclaw.app.memory.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface MemoryDao {

  // ---- Episodes ----

  @Insert(onConflict = OnConflictStrategy.REPLACE)
  suspend fun insertEpisode(episode: EpisodeEntity)

  @Query("SELECT episodes.* FROM episodes JOIN episodes_fts ON episodes.rowid = episodes_fts.rowid WHERE episodes_fts MATCH :query LIMIT :limit")
  suspend fun searchEpisodesFts(query: String, limit: Int): List<EpisodeEntity>

  @Query("SELECT * FROM episodes ORDER BY created_at DESC LIMIT :limit")
  suspend fun getRecentEpisodes(limit: Int): List<EpisodeEntity>

  @Query("UPDATE episodes SET last_accessed_at = :now WHERE id = :id")
  suspend fun touchEpisode(id: String, now: Long)

  // ---- Repairs ----

  @Insert(onConflict = OnConflictStrategy.REPLACE)
  suspend fun insertRepair(repair: RepairEntity)

  @Query("SELECT * FROM repairs WHERE skill_name = :skillName ORDER BY created_at DESC LIMIT :limit")
  suspend fun getRepairsBySkill(skillName: String, limit: Int): List<RepairEntity>

  @Query("SELECT repairs.* FROM repairs JOIN repairs_fts ON repairs.rowid = repairs_fts.rowid WHERE repairs_fts MATCH :query LIMIT :limit")
  suspend fun searchRepairsFts(query: String, limit: Int): List<RepairEntity>

  @Query("UPDATE repairs SET last_accessed_at = :now WHERE id = :id")
  suspend fun touchRepair(id: String, now: Long)

  // ---- Device Facts ----

  @Insert(onConflict = OnConflictStrategy.REPLACE)
  suspend fun insertDeviceFact(fact: DeviceFactEntity)

  @Query("SELECT * FROM device_facts ORDER BY last_accessed_at DESC")
  suspend fun getAllDeviceFacts(): List<DeviceFactEntity>

  @Query("SELECT * FROM device_facts WHERE fact_key = :key LIMIT 1")
  suspend fun getDeviceFactByKey(key: String): DeviceFactEntity?

  @Query("UPDATE device_facts SET last_accessed_at = :now WHERE id = :id")
  suspend fun touchDeviceFact(id: String, now: Long)

  // ---- LRU Eviction ----

  @Query("DELETE FROM episodes WHERE id IN (SELECT id FROM episodes ORDER BY last_accessed_at ASC LIMIT :count)")
  suspend fun evictOldestEpisodes(count: Int)

  @Query("DELETE FROM repairs WHERE id IN (SELECT id FROM repairs ORDER BY last_accessed_at ASC LIMIT :count)")
  suspend fun evictOldestRepairs(count: Int)

  @Query("DELETE FROM device_facts WHERE id IN (SELECT id FROM device_facts ORDER BY last_accessed_at ASC LIMIT :count)")
  suspend fun evictOldestDeviceFacts(count: Int)

  // ---- Clear All ----

  @Query("DELETE FROM episodes")
  suspend fun deleteAllEpisodes()

  @Query("DELETE FROM repairs")
  suspend fun deleteAllRepairs()

  @Query("DELETE FROM device_facts")
  suspend fun deleteAllDeviceFacts()

  // ---- Counts ----

  @Query("SELECT COUNT(*) FROM episodes")
  suspend fun episodeCount(): Int

  @Query("SELECT COUNT(*) FROM repairs")
  suspend fun repairCount(): Int

  @Query("SELECT COUNT(*) FROM device_facts")
  suspend fun deviceFactCount(): Int
}
