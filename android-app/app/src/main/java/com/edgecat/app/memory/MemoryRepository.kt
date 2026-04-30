package com.edgecat.app.memory

interface MemoryRepository {
  suspend fun saveEpisode(episode: Episode)
  suspend fun saveRepair(repair: RepairRecord)
  suspend fun saveDeviceFact(key: String, value: String, sourceEpisodeId: String? = null)
  suspend fun recallForPlanning(userMessage: String, tokenBudget: Int = 2048): String
  suspend fun recallRepairs(skillName: String, error: String, limit: Int = 3): List<RepairRecord>
  suspend fun getDeviceFacts(): List<DeviceFact>
  suspend fun evictIfNeeded(maxSizeBytes: Long = 100L * 1024 * 1024)
  suspend fun clearAll()
}
