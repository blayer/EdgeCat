package com.edgecat.app.memory.db

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Fts4
import androidx.room.PrimaryKey

// ---- Episodes ----

@Entity(tableName = "episodes")
data class EpisodeEntity(
  @PrimaryKey val id: String,
  @ColumnInfo(name = "user_message") val userMessage: String,
  val goal: String,
  @ColumnInfo(name = "skills_used") val skillsUsed: String, // comma-separated
  val outcome: String, // "success", "partial", "failure"
  @ColumnInfo(name = "step_count") val stepCount: Int,
  @ColumnInfo(name = "final_output") val finalOutput: String, // truncated to 500 chars
  val keywords: String, // space-separated, for FTS
  @ColumnInfo(name = "created_at") val createdAt: Long,
  @ColumnInfo(name = "last_accessed_at") val lastAccessedAt: Long,
)

@Fts4(contentEntity = EpisodeEntity::class)
@Entity(tableName = "episodes_fts")
data class EpisodeFts(
  val keywords: String,
  @ColumnInfo(name = "user_message") val userMessage: String,
  val goal: String,
)

// ---- Repairs ----

@Entity(tableName = "repairs")
data class RepairEntity(
  @PrimaryKey val id: String,
  @ColumnInfo(name = "skill_name") val skillName: String,
  @ColumnInfo(name = "error_summary") val errorSummary: String, // truncated to 200 chars
  @ColumnInfo(name = "fix_type") val fixType: String,
  @ColumnInfo(name = "fix_description") val fixDescription: String,
  @ColumnInfo(name = "alternative_skill") val alternativeSkill: String?, // nullable
  @ColumnInfo(name = "alternative_args") val alternativeArgs: String, // JSON string
  val success: Boolean,
  val keywords: String, // space-separated, for FTS
  @ColumnInfo(name = "created_at") val createdAt: Long,
  @ColumnInfo(name = "last_accessed_at") val lastAccessedAt: Long,
)

@Fts4(contentEntity = RepairEntity::class)
@Entity(tableName = "repairs_fts")
data class RepairFts(
  val keywords: String,
  @ColumnInfo(name = "skill_name") val skillName: String,
  @ColumnInfo(name = "error_summary") val errorSummary: String,
)

// ---- Device Facts ----

@Entity(tableName = "device_facts")
data class DeviceFactEntity(
  @PrimaryKey val id: String,
  @ColumnInfo(name = "fact_key") val factKey: String, // e.g., "alt_skill_set-alarm"
  @ColumnInfo(name = "fact_value") val factValue: String,
  @ColumnInfo(name = "source_episode_id") val sourceEpisodeId: String?, // nullable
  val keywords: String, // space-separated, for FTS
  @ColumnInfo(name = "created_at") val createdAt: Long,
  @ColumnInfo(name = "last_accessed_at") val lastAccessedAt: Long,
)

@Fts4(contentEntity = DeviceFactEntity::class)
@Entity(tableName = "device_facts_fts")
data class DeviceFactFts(
  val keywords: String,
  @ColumnInfo(name = "fact_key") val factKey: String,
  @ColumnInfo(name = "fact_value") val factValue: String,
)
