package com.mobileclaw.app.memory

data class Episode(
  val id: String,
  val userMessage: String,
  val goal: String,
  val skillsUsed: List<String>,
  val outcome: String, // "success", "partial", "failure"
  val stepCount: Int,
  val finalOutput: String,
)

data class RepairRecord(
  val id: String,
  val skillName: String,
  val errorSummary: String,
  val fixType: String,
  val fixDescription: String,
  val alternativeSkill: String? = null,
  val alternativeArgs: Map<String, String> = emptyMap(),
  val success: Boolean,
)

data class DeviceFact(
  val id: String,
  val factKey: String,
  val factValue: String,
  val sourceEpisodeId: String? = null,
)
