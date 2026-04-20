/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 */

package com.mobileclaw.app.ingest

import android.app.Activity
import android.os.Bundle
import android.util.Log
import java.io.File
import java.io.IOException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

private const val TAG = "AGModelIngest"

private const val EXTRA_SOURCE = "source"
private const val EXTRA_MODEL_DIR = "model_dir"
private const val EXTRA_VERSION = "version"
private const val EXTRA_FILE_NAME = "file_name"
private const val EXTRA_OP_ID = "op_id"

private const val STATUS_DIR = "ingest_status"
private const val TMP_SUFFIX = ".ingest.tmp"

/**
 * Hidden entry point that moves a pre-staged model file into the canonical download layout under
 * the **app UID**, so eval runs can skip the multi-GB HTTP download without poisoning ownership.
 *
 * Why this exists:
 *   - `adb push` into `/sdcard/Android/data/<pkg>/files/...` creates files owned by `shell`.
 *   - Samsung's FUSE layer then blocks the app from writing siblings (see `DownloadWorker`
 *     EACCES failure when ancestors are shell-owned), so a raw sideload is unusable.
 *   - Running the copy inside this Activity flips the resulting file's owner to the app UID.
 *
 * Workflow (intended use from `android-app/test/eval/run.py`):
 *
 *   adb push model.litertlm /sdcard/Android/data/com.mobileclaw.app/files/model.litertlm
 *   adb shell am start \
 *     -a com.mobileclaw.app.MODEL_INGEST \
 *     -n com.mobileclaw.app/.ingest.ModelIngestActivity \
 *     --es source model.litertlm \
 *     --es model_dir Gemma_4_E2B_it \
 *     --es version 7fa1d78473894f7e736a21d920c3aa80f950c0db \
 *     --es file_name gemma-4-E2B-it.litertlm
 *
 * Status:
 *   A JSON file at `externalFilesDir/ingest_status/<op_id>.json` is written on completion so the
 *   caller can poll/verify without scraping logcat. `op_id` defaults to a timestamp if absent.
 */
class ModelIngestActivity : Activity() {
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    val opId = intent.getStringExtra(EXTRA_OP_ID) ?: System.currentTimeMillis().toString()
    val source = intent.getStringExtra(EXTRA_SOURCE)
    val modelDir = intent.getStringExtra(EXTRA_MODEL_DIR)
    val version = intent.getStringExtra(EXTRA_VERSION)
    val fileName = intent.getStringExtra(EXTRA_FILE_NAME)

    scope.launch {
      try {
        runIngest(opId, source, modelDir, version, fileName)
      } catch (t: Throwable) {
        Log.e(TAG, "unexpected error", t)
        writeStatus(opId, false, "unexpected: ${t.message}")
      } finally {
        finish()
      }
    }
  }

  private fun runIngest(
    opId: String,
    source: String?,
    modelDir: String?,
    version: String?,
    fileName: String?,
  ) {
    val externalFilesDir = getExternalFilesDir(null)
    if (externalFilesDir == null) {
      fail(opId, "externalFilesDir is null")
      return
    }
    if (
      source.isNullOrBlank() ||
        modelDir.isNullOrBlank() ||
        version.isNullOrBlank() ||
        fileName.isNullOrBlank()
    ) {
      fail(
        opId,
        "missing extras: source=$source, model_dir=$modelDir, version=$version, file_name=$fileName",
      )
      return
    }

    val src = File(externalFilesDir, source)
    if (!src.exists() || !src.isFile) {
      fail(opId, "source not found: ${src.absolutePath}")
      return
    }

    // Remove any previously-poisoned (shell-owned) subtree at model_dir so the fresh tree gets
    // created with the app UID. The parent (externalFilesDir) is always app-owned, so unlink
    // works regardless of the child's owner.
    val topDir = File(externalFilesDir, modelDir)
    if (topDir.exists() && !topDir.deleteRecursively()) {
      Log.w(TAG, "partial cleanup of ${topDir.absolutePath}; continuing")
    }

    val destDir = File(topDir, version)
    if (!destDir.mkdirs() && !destDir.isDirectory) {
      fail(opId, "cannot create destDir ${destDir.absolutePath}")
      return
    }

    val dest = File(destDir, fileName)
    val tmp = File(destDir, "$fileName$TMP_SUFFIX")
    try {
      src.inputStream().use { input ->
        tmp.outputStream().use { output -> input.copyTo(output, DEFAULT_BUFFER_SIZE) }
      }
    } catch (e: IOException) {
      tmp.delete()
      fail(opId, "copy failed: ${e.message}")
      return
    }

    if (dest.exists()) dest.delete()
    if (!tmp.renameTo(dest)) {
      fail(opId, "rename failed: ${tmp.absolutePath} -> ${dest.absolutePath}")
      return
    }

    if (!src.delete()) {
      // Not fatal — the ingest itself succeeded. Leave a warning so stragglers are visible.
      Log.w(TAG, "could not delete source ${src.absolutePath}")
    }

    val bytes = dest.length()
    Log.i(TAG, "ingest success: ${dest.absolutePath} ($bytes bytes)")
    writeStatus(opId, true, "ingested $bytes bytes to ${dest.absolutePath}")
  }

  private fun fail(opId: String, detail: String) {
    Log.e(TAG, "ingest failed: $detail")
    writeStatus(opId, false, detail)
  }

  private fun writeStatus(opId: String, ok: Boolean, detail: String) {
    try {
      val externalFilesDir = getExternalFilesDir(null) ?: return
      val statusDir = File(externalFilesDir, STATUS_DIR).apply { mkdirs() }
      val statusFile = File(statusDir, "$opId.json")
      val escaped = detail.replace("\\", "\\\\").replace("\"", "\\\"")
      statusFile.writeText(
        """{"op_id":"$opId","ok":$ok,"detail":"$escaped","ts":${System.currentTimeMillis()}}"""
      )
    } catch (e: Exception) {
      Log.e(TAG, "writeStatus failed", e)
    }
  }
}
