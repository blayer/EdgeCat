package com.mobileclaw.app.memory

import android.util.Log
import com.mobileclaw.app.memory.db.DeviceFactEntity
import com.mobileclaw.app.memory.db.EpisodeEntity
import com.mobileclaw.app.memory.db.MemoryDao
import com.mobileclaw.app.memory.db.RepairEntity
import java.util.UUID
import org.json.JSONObject

private const val TAG = "AGMemory"

// Context budget: ~2048 tokens ≈ 8192 chars
private const val DEVICE_FACTS_BUDGET = 800
private const val REPAIR_BUDGET = 2400
private const val EPISODE_BUDGET = 4800
private const val MAX_DEVICE_FACTS = 10
private const val MAX_REPAIRS = 3
private const val MAX_EPISODES = 5

class DefaultMemoryRepository(
  private val dao: MemoryDao,
) : MemoryRepository {

  override suspend fun saveEpisode(episode: Episode) {
    val now = System.currentTimeMillis()
    val keywords = extractKeywords(episode.userMessage + " " + episode.goal)
    dao.insertEpisode(
      EpisodeEntity(
        id = episode.id,
        userMessage = episode.userMessage,
        goal = episode.goal,
        skillsUsed = episode.skillsUsed.joinToString(","),
        outcome = episode.outcome,
        stepCount = episode.stepCount,
        finalOutput = episode.finalOutput.take(500),
        keywords = keywords,
        createdAt = now,
        lastAccessedAt = now,
      )
    )
    Log.d(TAG, "Saved episode ${episode.id}: outcome=${episode.outcome}, skills=${episode.skillsUsed}")
  }

  override suspend fun saveRepair(repair: RepairRecord) {
    val now = System.currentTimeMillis()
    val keywords = extractKeywords(repair.skillName + " " + repair.errorSummary + " " + repair.fixDescription)
    val argsJson = if (repair.alternativeArgs.isNotEmpty()) {
      JSONObject(repair.alternativeArgs as Map<*, *>).toString()
    } else "{}"

    dao.insertRepair(
      RepairEntity(
        id = repair.id,
        skillName = repair.skillName,
        errorSummary = repair.errorSummary.take(200),
        fixType = repair.fixType,
        fixDescription = repair.fixDescription,
        alternativeSkill = repair.alternativeSkill,
        alternativeArgs = argsJson,
        success = repair.success,
        keywords = keywords,
        createdAt = now,
        lastAccessedAt = now,
      )
    )
    Log.d(TAG, "Saved repair ${repair.id}: skill=${repair.skillName}, fix=${repair.fixType}, success=${repair.success}")
  }

  override suspend fun saveDeviceFact(key: String, value: String, sourceEpisodeId: String?) {
    val now = System.currentTimeMillis()
    // Upsert: check if fact with same key already exists
    val existing = dao.getDeviceFactByKey(key)
    val id = existing?.id ?: UUID.randomUUID().toString()
    val keywords = extractKeywords(key + " " + value)

    dao.insertDeviceFact(
      DeviceFactEntity(
        id = id,
        factKey = key,
        factValue = value,
        sourceEpisodeId = sourceEpisodeId,
        keywords = keywords,
        createdAt = existing?.createdAt ?: now,
        lastAccessedAt = now,
      )
    )
    Log.d(TAG, "Saved device fact: $key = $value")
  }

  override suspend fun recallForPlanning(userMessage: String, tokenBudget: Int): String {
    val now = System.currentTimeMillis()
    val sections = mutableListOf<String>()

    // Priority 1: Device facts (always included)
    val facts = dao.getAllDeviceFacts().take(MAX_DEVICE_FACTS)
    if (facts.isNotEmpty()) {
      val factsBlock = buildString {
        append("[Device Knowledge]")
        var budget = DEVICE_FACTS_BUDGET
        for (fact in facts) {
          val line = "\n- ${fact.factValue}"
          if (line.length > budget) break
          append(line)
          budget -= line.length
          dao.touchDeviceFact(fact.id, now)
        }
      }
      sections.add(factsBlock)
    }

    // Priority 2: Repair patterns (matching keywords from user message)
    val queryTerms = extractKeywords(userMessage)
    if (queryTerms.isNotEmpty()) {
      val repairs = try {
        dao.searchRepairsFts(queryTerms, MAX_REPAIRS)
      } catch (e: Exception) {
        // FTS might fail if query has special chars; fall back to empty
        Log.w(TAG, "FTS repair search failed, skipping", e)
        emptyList()
      }
      if (repairs.isNotEmpty()) {
        val repairsBlock = buildString {
          append("[Past Repairs]")
          var budget = REPAIR_BUDGET
          for (repair in repairs) {
            val fix = when (repair.fixType) {
              "use_alternative_skill" -> "Use ${repair.alternativeSkill ?: "alternative"} instead"
              "retry_with_different_args" -> "Retry with different args: ${repair.alternativeArgs}"
              "update_instructions" -> "Updated skill instructions"
              else -> repair.fixDescription
            }
            val successStr = if (repair.success) "worked" else "did not work"
            val line = "\n- ${repair.skillName} failed: ${repair.errorSummary}. Fix: $fix ($successStr)"
            if (line.length > budget) break
            append(line)
            budget -= line.length
            dao.touchRepair(repair.id, now)
          }
        }
        sections.add(repairsBlock)
      }
    }

    // Priority 3: Similar past episodes
    if (queryTerms.isNotEmpty()) {
      val episodes = try {
        dao.searchEpisodesFts(queryTerms, MAX_EPISODES)
      } catch (e: Exception) {
        Log.w(TAG, "FTS episode search failed, skipping", e)
        emptyList()
      }
      if (episodes.isNotEmpty()) {
        val episodesBlock = buildString {
          append("[Similar Past Tasks]")
          var budget = EPISODE_BUDGET
          for (ep in episodes) {
            val skills = if (ep.skillsUsed.isNotBlank()) ep.skillsUsed else "none"
            val line = "\n- \"${ep.userMessage.take(80)}\" -> skills: $skills, outcome: ${ep.outcome}"
            if (line.length > budget) break
            append(line)
            budget -= line.length
            dao.touchEpisode(ep.id, now)
          }
        }
        sections.add(episodesBlock)
      }
    }

    val result = sections.joinToString("\n\n")
    if (result.isNotEmpty()) {
      Log.d(TAG, "Recalled ${result.length} chars of memory context for planning")
    }
    return result
  }

  override suspend fun recallRepairs(skillName: String, error: String, limit: Int): List<RepairRecord> {
    val now = System.currentTimeMillis()
    val entities = dao.getRepairsBySkill(skillName, limit)
    return entities.map { entity ->
      dao.touchRepair(entity.id, now)
      val altArgs = parseJsonArgs(entity.alternativeArgs)
      RepairRecord(
        id = entity.id,
        skillName = entity.skillName,
        errorSummary = entity.errorSummary,
        fixType = entity.fixType,
        fixDescription = entity.fixDescription,
        alternativeSkill = entity.alternativeSkill,
        alternativeArgs = altArgs,
        success = entity.success,
      )
    }
  }

  override suspend fun getDeviceFacts(): List<DeviceFact> {
    return dao.getAllDeviceFacts().map { entity ->
      DeviceFact(
        id = entity.id,
        factKey = entity.factKey,
        factValue = entity.factValue,
        sourceEpisodeId = entity.sourceEpisodeId,
      )
    }
  }

  override suspend fun evictIfNeeded(maxSizeBytes: Long) {
    // Approximate size: count records and estimate ~1KB per record
    val totalRecords = dao.episodeCount() + dao.repairCount() + dao.deviceFactCount()
    val estimatedBytes = totalRecords * 1024L

    if (estimatedBytes <= maxSizeBytes) return

    val excess = ((estimatedBytes - maxSizeBytes) / 1024).toInt().coerceAtLeast(1)
    Log.d(TAG, "Evicting ~$excess records (estimated ${estimatedBytes / 1024}KB > ${maxSizeBytes / 1024}KB)")

    // Evict proportionally: episodes first (largest), then repairs
    val episodesToEvict = (excess * 2 / 3).coerceAtLeast(1)
    val repairsToEvict = (excess / 3).coerceAtLeast(1)

    dao.evictOldestEpisodes(episodesToEvict)
    dao.evictOldestRepairs(repairsToEvict)
    // Device facts are rarely evicted — they're high-value, low-count
  }

  /** Extract keywords from text: lowercase, deduplicate, remove stopwords. */
  internal fun extractKeywords(text: String): String {
    val stopwords = setOf(
      "a", "an", "the", "is", "are", "was", "were", "be", "been", "being",
      "have", "has", "had", "do", "does", "did", "will", "would", "could",
      "should", "may", "might", "shall", "can", "need", "dare", "ought",
      "to", "of", "in", "for", "on", "with", "at", "by", "from", "as",
      "into", "through", "during", "before", "after", "above", "below",
      "between", "and", "but", "or", "nor", "not", "so", "yet", "both",
      "either", "neither", "each", "every", "all", "any", "few", "more",
      "most", "other", "some", "such", "no", "only", "own", "same", "than",
      "too", "very", "just", "because", "if", "when", "where", "how", "what",
      "which", "who", "whom", "this", "that", "these", "those", "i", "me",
      "my", "we", "our", "you", "your", "he", "him", "his", "she", "her",
      "it", "its", "they", "them", "their", "up", "then", "get", "set",
      "null", "unknown",
    )

    return text.lowercase()
      .replace(Regex("[^a-z0-9\\s-]"), " ")
      .split(Regex("\\s+"))
      .filter { it.length > 2 && it !in stopwords }
      .distinct()
      .take(20)
      .joinToString(" ")
  }

  private fun parseJsonArgs(json: String): Map<String, String> {
    if (json.isBlank() || json == "{}") return emptyMap()
    return try {
      val obj = JSONObject(json)
      val map = mutableMapOf<String, String>()
      for (key in obj.keys()) {
        map[key] = obj.optString(key, "")
      }
      map
    } catch (e: Exception) {
      emptyMap()
    }
  }
}
