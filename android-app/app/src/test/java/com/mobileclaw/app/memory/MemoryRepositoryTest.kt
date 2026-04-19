package com.mobileclaw.app.memory

import com.mobileclaw.app.memory.db.DeviceFactEntity
import com.mobileclaw.app.memory.db.EpisodeEntity
import com.mobileclaw.app.memory.db.MemoryDao
import com.mobileclaw.app.memory.db.RepairEntity
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class MemoryRepositoryTest {

  private lateinit var fakeDao: FakeMemoryDao
  private lateinit var repo: DefaultMemoryRepository

  @Before
  fun setup() {
    fakeDao = FakeMemoryDao()
    repo = DefaultMemoryRepository(fakeDao)
  }

  @Test
  fun `saveEpisode stores episode in dao`() = runTest {
    val episode = Episode(
      id = "ep-1",
      userMessage = "Set an alarm for 6am",
      goal = "Set alarm",
      skillsUsed = listOf("set-alarm"),
      outcome = "success",
      stepCount = 1,
      finalOutput = "Alarm set for 6:00 AM",
    )
    repo.saveEpisode(episode)
    assertEquals(1, fakeDao.episodes.size)
    assertEquals("ep-1", fakeDao.episodes[0].id)
    assertEquals("success", fakeDao.episodes[0].outcome)
  }

  @Test
  fun `saveRepair stores repair in dao`() = runTest {
    val repair = RepairRecord(
      id = "rep-1",
      skillName = "set-alarm",
      errorSummary = "ActivityNotFoundException",
      fixType = "use_alternative_skill",
      fixDescription = "No Clock app on this device",
      alternativeSkill = "set-reminder",
      success = true,
    )
    repo.saveRepair(repair)
    assertEquals(1, fakeDao.repairs.size)
    assertEquals("set-alarm", fakeDao.repairs[0].skillName)
    assertTrue(fakeDao.repairs[0].success)
  }

  @Test
  fun `saveDeviceFact upserts by key`() = runTest {
    repo.saveDeviceFact("alt_skill_set-alarm", "Use set-reminder instead")
    assertEquals(1, fakeDao.deviceFacts.size)

    // Save again with same key — should update, not duplicate
    repo.saveDeviceFact("alt_skill_set-alarm", "Use create-calendar-event instead")
    // FakeDao uses REPLACE strategy on id, so check we still have 1
    assertEquals(1, fakeDao.deviceFacts.size)
    assertEquals("Use create-calendar-event instead", fakeDao.deviceFacts[0].factValue)
  }

  @Test
  fun `recallForPlanning returns empty when no data`() = runTest {
    val result = repo.recallForPlanning("Set an alarm")
    assertEquals("", result)
  }

  @Test
  fun `recallForPlanning includes device facts`() = runTest {
    repo.saveDeviceFact("alt_skill_set-alarm", "Use set-reminder instead of set-alarm on this device")
    val result = repo.recallForPlanning("Set an alarm for 6am")
    assertTrue(result.contains("[Device Knowledge]"))
    assertTrue(result.contains("set-reminder"))
  }

  @Test
  fun `extractKeywords removes stopwords and deduplicates`() {
    val keywords = repo.extractKeywords("Set an alarm for tomorrow at 6am in the morning")
    assertTrue("alarm" in keywords)
    assertTrue("tomorrow" in keywords)
    // Stopwords like "an", "for", "at", "in", "the" should be removed
    assertTrue("for" !in keywords.split(" "))
    assertTrue("the" !in keywords.split(" "))
  }

  @Test
  fun `recallRepairs returns repairs for skill`() = runTest {
    val repair = RepairRecord(
      id = "rep-1",
      skillName = "set-alarm",
      errorSummary = "ActivityNotFoundException",
      fixType = "use_alternative_skill",
      fixDescription = "No Clock app",
      alternativeSkill = "set-reminder",
      success = true,
    )
    repo.saveRepair(repair)
    val results = repo.recallRepairs("set-alarm", "ActivityNotFoundException")
    assertEquals(1, results.size)
    assertEquals("use_alternative_skill", results[0].fixType)
  }

  @Test
  fun `evictIfNeeded does nothing under limit`() = runTest {
    repo.saveEpisode(Episode("e1", "test", "test", emptyList(), "success", 1, ""))
    repo.evictIfNeeded(100L * 1024 * 1024)
    assertEquals(1, fakeDao.episodes.size)
  }
}

/** In-memory fake DAO for unit tests. */
class FakeMemoryDao : MemoryDao {
  val episodes = mutableListOf<EpisodeEntity>()
  val repairs = mutableListOf<RepairEntity>()
  val deviceFacts = mutableListOf<DeviceFactEntity>()

  override suspend fun insertEpisode(episode: EpisodeEntity) {
    episodes.removeAll { it.id == episode.id }
    episodes.add(episode)
  }

  override suspend fun searchEpisodesFts(query: String, limit: Int): List<EpisodeEntity> {
    // Simple keyword match for testing
    val terms = query.lowercase().split(" ")
    return episodes.filter { ep ->
      terms.any { term -> ep.keywords.contains(term) || ep.userMessage.lowercase().contains(term) }
    }.take(limit)
  }

  override suspend fun getRecentEpisodes(limit: Int): List<EpisodeEntity> {
    return episodes.sortedByDescending { it.createdAt }.take(limit)
  }

  override suspend fun touchEpisode(id: String, now: Long) {
    val idx = episodes.indexOfFirst { it.id == id }
    if (idx >= 0) episodes[idx] = episodes[idx].copy(lastAccessedAt = now)
  }

  override suspend fun insertRepair(repair: RepairEntity) {
    repairs.removeAll { it.id == repair.id }
    repairs.add(repair)
  }

  override suspend fun getRepairsBySkill(skillName: String, limit: Int): List<RepairEntity> {
    return repairs.filter { it.skillName == skillName }.take(limit)
  }

  override suspend fun searchRepairsFts(query: String, limit: Int): List<RepairEntity> {
    val terms = query.lowercase().split(" ")
    return repairs.filter { r ->
      terms.any { term -> r.keywords.contains(term) || r.skillName.contains(term) }
    }.take(limit)
  }

  override suspend fun touchRepair(id: String, now: Long) {
    val idx = repairs.indexOfFirst { it.id == id }
    if (idx >= 0) repairs[idx] = repairs[idx].copy(lastAccessedAt = now)
  }

  override suspend fun insertDeviceFact(fact: DeviceFactEntity) {
    deviceFacts.removeAll { it.id == fact.id }
    deviceFacts.add(fact)
  }

  override suspend fun getAllDeviceFacts(): List<DeviceFactEntity> {
    return deviceFacts.sortedByDescending { it.lastAccessedAt }
  }

  override suspend fun getDeviceFactByKey(key: String): DeviceFactEntity? {
    return deviceFacts.find { it.factKey == key }
  }

  override suspend fun touchDeviceFact(id: String, now: Long) {
    val idx = deviceFacts.indexOfFirst { it.id == id }
    if (idx >= 0) deviceFacts[idx] = deviceFacts[idx].copy(lastAccessedAt = now)
  }

  override suspend fun evictOldestEpisodes(count: Int) {
    val sorted = episodes.sortedBy { it.lastAccessedAt }
    val toRemove = sorted.take(count).map { it.id }.toSet()
    episodes.removeAll { it.id in toRemove }
  }

  override suspend fun evictOldestRepairs(count: Int) {
    val sorted = repairs.sortedBy { it.lastAccessedAt }
    val toRemove = sorted.take(count).map { it.id }.toSet()
    repairs.removeAll { it.id in toRemove }
  }

  override suspend fun evictOldestDeviceFacts(count: Int) {
    val sorted = deviceFacts.sortedBy { it.lastAccessedAt }
    val toRemove = sorted.take(count).map { it.id }.toSet()
    deviceFacts.removeAll { it.id in toRemove }
  }

  override suspend fun deleteAllEpisodes() { episodes.clear() }
  override suspend fun deleteAllRepairs() { repairs.clear() }
  override suspend fun deleteAllDeviceFacts() { deviceFacts.clear() }

  override suspend fun episodeCount(): Int = episodes.size
  override suspend fun repairCount(): Int = repairs.size
  override suspend fun deviceFactCount(): Int = deviceFacts.size
}
