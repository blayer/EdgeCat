/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 */

package com.edgecat.app.eval

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Process-wide state holder the headless [EvalActivity] UI watches and the
 * eval orchestration code publishes to. Mirrors iOS's `EvalRunStatus` (see
 * `ios-app-wip/EdgeCat/App/EvalRunStatus.swift`) so the eval-mode surface
 * looks the same across platforms: a status pill that walks
 * idle → loadingModel → running → completed/failed.
 *
 * Singleton because there is exactly one in-flight eval per process — a
 * second `am start --es prompt …` race would force-stop the app first
 * (see `start_eval()` in `test/eval/run.py`), so concurrent state is
 * impossible by construction.
 */
object EvalRunStatus {
  enum class Phase { IDLE, LOADING_MODEL, RUNNING, COMPLETED, FAILED }

  data class State(
    val phase: Phase = Phase.IDLE,
    val prompt: String = "",
    val runId: String = "",
    val modelName: String = "",
    val detail: String = "",
    /** User tapped "Exit eval mode" from the status surface. The activity
     *  watches this and finishes; the off-device runner doesn't see it. */
    val exited: Boolean = false,
  )

  private val _state = MutableStateFlow(State())
  val state: StateFlow<State> = _state.asStateFlow()

  /** Start a new eval. For multi-turn the prompt is the first turn's text. */
  fun begin(prompt: String, runId: String, modelName: String = "") {
    _state.value = State(
      phase = Phase.LOADING_MODEL,
      prompt = prompt,
      runId = runId,
      modelName = modelName,
      detail = "Loading model…",
    )
  }

  fun transition(phase: Phase, detail: String? = null) {
    _state.value = _state.value.copy(
      phase = phase,
      detail = detail ?: _state.value.detail,
    )
  }

  fun setModelName(name: String) {
    _state.value = _state.value.copy(modelName = name)
  }

  fun setDetail(detail: String) {
    _state.value = _state.value.copy(detail = detail)
  }

  fun reset() {
    _state.value = State()
  }

  fun requestExit() {
    _state.value = _state.value.copy(exited = true)
  }
}
