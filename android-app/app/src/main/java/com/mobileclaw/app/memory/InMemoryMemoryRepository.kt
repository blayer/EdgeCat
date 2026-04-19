package com.mobileclaw.app.memory

/**
 * In-memory, non-persistent MemoryRepository.
 *
 * Used by the eval harness (EvalActivity) so each eval task runs with a fresh,
 * isolated memory. The planner → evaluator → replan loop inside a single task
 * still sees and writes memory (episodes, repairs, device facts) the same way
 * the production repository would; the state is just discarded when the task ends.
 *
 * Holds everything in process memory — do not use for production user chat.
 */
class InMemoryMemoryRepository : MemoryRepository {
  private val lock = Any()
  private val episodes = mutableListOf<Episode>()
  private val repairs = mutableListOf<RepairRecord>()
  private val deviceFacts = mutableListOf<DeviceFact>()

  override suspend fun saveEpisode(episode: Episode) {
    synchronized(lock) { episodes.add(episode) }
  }

  override suspend fun saveRepair(repair: RepairRecord) {
    synchronized(lock) { repairs.add(repair) }
  }

  override suspend fun saveDeviceFact(key: String, value: String, sourceEpisodeId: String?) {
    synchronized(lock) {
      deviceFacts.removeAll { it.factKey == key }
      deviceFacts.add(
        DeviceFact(
          id = java.util.UUID.randomUUID().toString(),
          factKey = key,
          factValue = value,
          sourceEpisodeId = sourceEpisodeId,
        )
      )
    }
  }

  override suspend fun recallForPlanning(userMessage: String, tokenBudget: Int): String =
    synchronized(lock) {
      if (episodes.isEmpty() && repairs.isEmpty() && deviceFacts.isEmpty()) return ""
      val sb = StringBuilder()
      if (deviceFacts.isNotEmpty()) {
        sb.append("Device facts:\n")
        for (f in deviceFacts.takeLast(10)) sb.append("- ${f.factKey}: ${f.factValue}\n")
      }
      if (episodes.isNotEmpty()) {
        sb.append("Recent episodes:\n")
        for (e in episodes.takeLast(5)) {
          sb.append("- ${e.goal} → ${e.outcome} (skills=${e.skillsUsed.joinToString(",")})\n")
        }
      }
      if (repairs.isNotEmpty()) {
        sb.append("Recent repairs:\n")
        for (r in repairs.takeLast(3)) {
          sb.append("- ${r.skillName}: ${r.errorSummary} → ${r.fixDescription}\n")
        }
      }
      sb.toString()
    }

  override suspend fun recallRepairs(skillName: String, error: String, limit: Int): List<RepairRecord> =
    synchronized(lock) {
      val key = error.lowercase()
      repairs
        .asReversed()
        .filter { it.skillName == skillName && (key.isEmpty() || it.errorSummary.lowercase().contains(key)) }
        .take(limit)
    }

  override suspend fun getDeviceFacts(): List<DeviceFact> = synchronized(lock) { deviceFacts.toList() }

  override suspend fun evictIfNeeded(maxSizeBytes: Long) { /* in-memory; nothing to evict */ }

  override suspend fun clearAll() {
    synchronized(lock) {
      episodes.clear()
      repairs.clear()
      deviceFacts.clear()
    }
  }
}
