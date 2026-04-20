package com.mobileclaw.app.customtasks.agentchat

import android.Manifest
import android.app.NotificationManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.database.Cursor
import android.hardware.camera2.CameraManager
import android.location.Geocoder
import android.location.LocationManager
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.provider.AlarmClock
import android.provider.CalendarContract
import android.provider.ContactsContract
import android.provider.MediaStore
import android.telephony.SmsManager
import android.util.Log
import androidx.core.content.ContextCompat
import com.mobileclaw.app.common.AgentAction
import com.mobileclaw.app.common.RequestPermissionAgentAction
import com.mobileclaw.app.common.SkillProgressAgentAction
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.withTimeout
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

private const val TAG = "AGDeviceSkills"
private const val PERMISSION_UI_TIMEOUT_MS = 30_000L

/**
 * Native Android device skills — separate from JS/MCP skills.
 *
 * Each method implements a device-level capability (SMS, calendar, contacts, photos, apps).
 * These are called by AgentTools @Tool methods which delegate here.
 */
class DeviceSkills(
  private val contextProvider: () -> Context,
  private val actionChannel: SendChannel<AgentAction>,
) {
  private val context: Context get() = contextProvider()

  // ─── Permission helper ───

  private suspend fun ensurePermission(vararg permissions: String, rationale: String): Boolean {
    val missing = permissions.filter {
      ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED
    }
    if (missing.isEmpty()) return true

    val action = RequestPermissionAgentAction(
      permissions = missing,
      rationale = rationale,
    )
    actionChannel.send(action)
    // Bounded wait: if no UI resolves this within PERMISSION_UI_TIMEOUT_MS (e.g. headless
    // EvalActivity, backgrounded process, crashed dialog), fast-fail instead of hanging
    // the whole orchestration loop. Production UI normally resolves in <1s once the
    // permission dialog appears; 30s is well above that and below typical per-task budgets.
    return try {
      withTimeout(PERMISSION_UI_TIMEOUT_MS) { action.result.await() }
    } catch (_: TimeoutCancellationException) {
      Log.w(TAG, "Permission request for $missing timed out after ${PERMISSION_UI_TIMEOUT_MS}ms; " +
        "treating as denied (no UI available?)")
      false
    }
  }

  private suspend fun sendProgress(label: String, inProgress: Boolean, title: String = "", desc: String = "") {
    actionChannel.send(
      SkillProgressAgentAction(
        label = label,
        inProgress = inProgress,
        addItemTitle = title.ifEmpty { label },
        addItemDescription = desc,
      )
    )
  }

  // ─── SMS ───

  suspend fun sendSms(phoneNumber: String, messageBody: String): Map<String, String> {
    sendProgress("Sending SMS to $phoneNumber", inProgress = true, title = "Send SMS", desc = "To: $phoneNumber")

    if (!ensurePermission(Manifest.permission.SEND_SMS, rationale = "Send SMS messages")) {
      return mapOf("status" to "failed", "error" to "SMS permission denied")
    }

    return try {
      val smsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        context.getSystemService(SmsManager::class.java)
      } else {
        @Suppress("DEPRECATION")
        SmsManager.getDefault()
      }
      smsManager.sendTextMessage(phoneNumber.trim(), null, messageBody, null, null)
      Log.d(TAG, "SMS sent to $phoneNumber")
      mapOf("status" to "succeeded", "phone_number" to phoneNumber, "message" to "SMS sent successfully")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to send SMS", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to send SMS"))
    }
  }

  // ─── Email (opens email app — no special permission needed) ───

  suspend fun sendEmail(to: String, subject: String, body: String): Map<String, String> {
    sendProgress("Composing email to $to", inProgress = true, title = "Send Email", desc = "To: $to, Subject: $subject")

    return try {
      val intent = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_EMAIL, arrayOf(to))
        putExtra(Intent.EXTRA_SUBJECT, subject)
        putExtra(Intent.EXTRA_TEXT, body)
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      }
      context.startActivity(intent)
      mapOf("status" to "succeeded", "message" to "Email compose opened for $to")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to open email", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to open email"))
    }
  }

  // ─── Calendar: CRUD ───

  suspend fun manageCalendar(action: String, args: Map<String, String>): Map<String, Any> {
    return when (action.lowercase().replace("-", "_")) {
      "create" -> {
        val reminderMin = args["reminderMinutes"]?.toIntOrNull()
        if (reminderMin != null) {
          setReminder(args["title"] ?: "", args["startDateTime"] ?: args["dateTime"] ?: "", reminderMin)
        } else {
          createCalendarEvent(
            args["title"] ?: "",
            args["startDateTime"] ?: "",
            args["endDateTime"] ?: "",
            args["location"] ?: "",
            args["description"] ?: "",
          )
        }
      }
      "read" -> readCalendarEvents(args["startDate"] ?: "", args["endDate"] ?: "")
      "edit" -> editCalendarEvent(args)
      "delete" -> {
        val eid = args["eventId"]
          ?: args["title"]?.let { findEventIdByTitle(it)?.toString() }
          ?: args["eventTitle"]?.let { findEventIdByTitle(it)?.toString() }
          ?: args["name"]?.let { findEventIdByTitle(it)?.toString() }
        if (eid.isNullOrBlank()) {
          mapOf("status" to "failed", "error" to "No eventId or title provided to find the event")
        } else {
          deleteCalendarEvent(eid)
        }
      }
      else -> mapOf("status" to "failed", "error" to "Unknown action: $action. Use: create, read, edit, delete")
    }
  }

  // ─── Timer / Alarm ───

  suspend fun manageTimer(action: String, args: Map<String, String>): Map<String, Any> {
    return when (action.lowercase().replace("-", "_")) {
      "set_alarm" -> setAlarm(
        args["hour"]?.toIntOrNull() ?: 0,
        args["minute"]?.toIntOrNull() ?: 0,
        args["label"] ?: "",
      )
      "set_timer" -> setTimer(
        args["durationSeconds"]?.toIntOrNull() ?: 60,
        args["label"] ?: "",
      )
      "show_alarms" -> showAlarms()
      "dismiss_alarm" -> dismissAlarm(args["label"] ?: "")
      else -> mapOf("status" to "failed", "error" to "Unknown action: $action. Use: set_alarm, set_timer, show_alarms, dismiss_alarm")
    }
  }

  private suspend fun readCalendarEvents(startDate: String, endDate: String): Map<String, Any> {
    // Default to today if dates are empty or unparseable
    val sdf = SimpleDateFormat("yyyy-MM-dd", Locale.US)
    sdf.timeZone = TimeZone.getDefault()
    val todayStr = sdf.format(java.util.Date())
    val effectiveStart = startDate.ifBlank { todayStr }
    val effectiveEnd = endDate.ifBlank { effectiveStart }

    sendProgress("Reading calendar events", inProgress = true, title = "Read Calendar", desc = "$effectiveStart to $effectiveEnd")

    if (!ensurePermission(Manifest.permission.READ_CALENDAR, rationale = "Read calendar events")) {
      return mapOf("status" to "failed", "error" to "Calendar permission denied")
    }

    return try {
      val startMillis = sdf.parse(effectiveStart)?.time ?: return mapOf("status" to "failed", "error" to "Invalid start date: $effectiveStart")
      val endCal = Calendar.getInstance().apply { time = sdf.parse(effectiveEnd) ?: return mapOf("status" to "failed", "error" to "Invalid end date: $effectiveEnd") }
      endCal.set(Calendar.HOUR_OF_DAY, 23)
      endCal.set(Calendar.MINUTE, 59)
      val endMillis = endCal.timeInMillis

      val projection = arrayOf(
        CalendarContract.Events._ID,
        CalendarContract.Events.TITLE,
        CalendarContract.Events.DTSTART,
        CalendarContract.Events.DTEND,
        CalendarContract.Events.EVENT_LOCATION,
        CalendarContract.Events.DESCRIPTION,
      )
      val selection = "${CalendarContract.Events.DTSTART} >= ? AND ${CalendarContract.Events.DTSTART} <= ?"
      val selectionArgs = arrayOf(startMillis.toString(), endMillis.toString())
      val sortOrder = "${CalendarContract.Events.DTSTART} ASC"

      val events = mutableListOf<Map<String, String>>()
      val cursor: Cursor? = context.contentResolver.query(
        CalendarContract.Events.CONTENT_URI, projection, selection, selectionArgs, sortOrder,
      )
      cursor?.use {
        val dtFormat = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US)
        while (it.moveToNext()) {
          events.add(mapOf(
            "id" to (it.getLong(0).toString()),
            "title" to (it.getString(1) ?: ""),
            "start" to dtFormat.format(it.getLong(2)),
            "end" to dtFormat.format(it.getLong(3)),
            "location" to (it.getString(4) ?: ""),
            "description" to (it.getString(5) ?: ""),
          ))
        }
      }
      Log.d(TAG, "Found ${events.size} calendar events")
      mapOf("status" to "succeeded", "count" to events.size.toString(), "events" to events.toString())
    } catch (e: Exception) {
      Log.e(TAG, "Failed to read calendar", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to read calendar"))
    }
  }

  private suspend fun createCalendarEvent(
    title: String, startDateTime: String, endDateTime: String, location: String, description: String,
  ): Map<String, String> {
    sendProgress("Creating calendar event: $title", inProgress = true, title = "Create Event", desc = title)

    if (!ensurePermission(Manifest.permission.WRITE_CALENDAR, Manifest.permission.READ_CALENDAR,
        rationale = "Create calendar events")) {
      return mapOf("status" to "failed", "error" to "Calendar permission denied")
    }

    return try {
      val startMillis = parseDateTimeLenient(startDateTime) ?: return mapOf("status" to "failed", "error" to "Invalid start date: $startDateTime")
      val endMillis = parseDateTimeLenient(endDateTime) ?: return mapOf("status" to "failed", "error" to "Invalid end date: $endDateTime")

      // Get default calendar ID.
      val calCursor = context.contentResolver.query(
        CalendarContract.Calendars.CONTENT_URI,
        arrayOf(CalendarContract.Calendars._ID),
        "${CalendarContract.Calendars.IS_PRIMARY} = 1",
        null, null,
      )
      val calId = calCursor?.use { if (it.moveToFirst()) it.getLong(0) else null } ?: 1L

      val values = android.content.ContentValues().apply {
        put(CalendarContract.Events.CALENDAR_ID, calId)
        put(CalendarContract.Events.TITLE, title)
        put(CalendarContract.Events.DTSTART, startMillis)
        put(CalendarContract.Events.DTEND, endMillis)
        put(CalendarContract.Events.EVENT_LOCATION, location)
        put(CalendarContract.Events.DESCRIPTION, description)
        put(CalendarContract.Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
      }
      val uri = context.contentResolver.insert(CalendarContract.Events.CONTENT_URI, values)
      val eventId = uri?.lastPathSegment ?: "unknown"
      Log.d(TAG, "Created calendar event: $eventId")
      mapOf("status" to "succeeded", "event_id" to eventId, "message" to "Event '$title' created")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to create calendar event", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to create event"))
    }
  }

  private suspend fun findEventIdByTitle(title: String): Long? {
    val cursor = context.contentResolver.query(
      CalendarContract.Events.CONTENT_URI,
      arrayOf(CalendarContract.Events._ID),
      "${CalendarContract.Events.TITLE} = ?",
      arrayOf(title),
      "${CalendarContract.Events.DTSTART} DESC",
    )
    return cursor?.use { if (it.moveToFirst()) it.getLong(0) else null }
  }

  private suspend fun editCalendarEvent(args: Map<String, String>): Map<String, String> {
    // Look up event by ID, or fall back to finding by title
    val lookupTitle = args["originalTitle"] ?: args["searchTitle"] ?: args["eventTitle"] ?: args["title"]
    val eventId = args["eventId"]
      ?: lookupTitle?.let { findEventIdByTitle(it)?.toString() }
      ?: return mapOf("status" to "failed", "error" to "Missing eventId or event title to look up")
    sendProgress("Editing event $eventId", inProgress = true, title = "Edit Event", desc = eventId)

    if (!ensurePermission(Manifest.permission.WRITE_CALENDAR, Manifest.permission.READ_CALENDAR,
        rationale = "Edit calendar events")) {
      return mapOf("status" to "failed", "error" to "Calendar permission denied")
    }

    return try {
      val values = ContentValues()
      // newTitle takes priority for renaming; otherwise fall back to title
      val newTitle = args["newTitle"] ?: args["newtitle"] ?: args["new_title"]
      if (newTitle != null) {
        values.put(CalendarContract.Events.TITLE, newTitle)
      } else {
        // Only set title if it's different from the lookup title (avoid no-op)
        args["title"]?.let { if (it != lookupTitle) values.put(CalendarContract.Events.TITLE, it) }
      }
      args["startDateTime"]?.let {
        parseDateTimeLenient(it)?.let { ms -> values.put(CalendarContract.Events.DTSTART, ms) }
      }
      args["endDateTime"]?.let {
        parseDateTimeLenient(it)?.let { ms -> values.put(CalendarContract.Events.DTEND, ms) }
      }
      args["location"]?.let { values.put(CalendarContract.Events.EVENT_LOCATION, it) }
      args["description"]?.let { values.put(CalendarContract.Events.DESCRIPTION, it) }

      if (values.size() == 0) {
        return mapOf("status" to "failed", "error" to "No fields to update")
      }

      val uri = android.content.ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId.toLong())
      val rows = context.contentResolver.update(uri, values, null, null)
      Log.d(TAG, "Updated $rows row(s) for event $eventId")
      if (rows > 0) {
        mapOf("status" to "succeeded", "message" to "Event $eventId updated")
      } else {
        mapOf("status" to "failed", "error" to "Event $eventId not found")
      }
    } catch (e: Exception) {
      Log.e(TAG, "Failed to edit calendar event", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to edit event"))
    }
  }

  private suspend fun deleteCalendarEvent(eventId: String): Map<String, String> {
    sendProgress("Deleting event $eventId", inProgress = true, title = "Delete Event", desc = eventId)

    if (!ensurePermission(Manifest.permission.WRITE_CALENDAR, rationale = "Delete calendar events")) {
      return mapOf("status" to "failed", "error" to "Calendar permission denied")
    }

    return try {
      val uri = android.content.ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId.toLong())
      val rows = context.contentResolver.delete(uri, null, null)
      Log.d(TAG, "Deleted $rows row(s) for event $eventId")
      if (rows > 0) {
        mapOf("status" to "succeeded", "message" to "Event $eventId deleted")
      } else {
        mapOf("status" to "failed", "error" to "Event $eventId not found")
      }
    } catch (e: Exception) {
      Log.e(TAG, "Failed to delete calendar event", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to delete event"))
    }
  }

  private suspend fun showAlarms(): Map<String, String> {
    sendProgress("Showing alarms", inProgress = true, title = "Show Alarms")
    return try {
      val intent = Intent(AlarmClock.ACTION_SHOW_ALARMS).apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      }
      context.startActivity(intent)
      mapOf("status" to "succeeded", "message" to "Clock app opened")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to show alarms", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to show alarms"))
    }
  }

  private suspend fun dismissAlarm(label: String): Map<String, String> {
    sendProgress("Dismissing alarm", inProgress = true, title = "Dismiss Alarm", desc = label)
    return try {
      val intent = Intent(AlarmClock.ACTION_DISMISS_ALARM).apply {
        if (label.isNotEmpty()) {
          putExtra(AlarmClock.EXTRA_ALARM_SEARCH_MODE, AlarmClock.ALARM_SEARCH_MODE_LABEL)
          putExtra(AlarmClock.EXTRA_MESSAGE, label)
        } else {
          putExtra(AlarmClock.EXTRA_ALARM_SEARCH_MODE, AlarmClock.ALARM_SEARCH_MODE_ALL)
        }
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      }
      context.startActivity(intent)
      mapOf("status" to "succeeded", "message" to "Alarm dismissed${if (label.isNotEmpty()) " ($label)" else ""}")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to dismiss alarm", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to dismiss alarm"))
    }
  }

  // ─── Contacts ───

  suspend fun readContacts(query: String, maxResults: Int): Map<String, Any> {
    sendProgress("Reading contacts", inProgress = true, title = "Read Contacts", desc = "Query: ${query.ifEmpty { "all" }}")

    if (!ensurePermission(Manifest.permission.READ_CONTACTS, rationale = "Read contacts")) {
      return mapOf("status" to "failed", "error" to "Contacts permission denied")
    }

    return try {
      val projection = arrayOf(
        ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
        ContactsContract.CommonDataKinds.Phone.NUMBER,
      )
      val selection = if (query.isNotEmpty()) {
        "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} LIKE ?"
      } else null
      val selectionArgs = if (query.isNotEmpty()) arrayOf("%$query%") else null
      val sortOrder = "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC"

      val contacts = mutableListOf<Map<String, String>>()
      val cursor = context.contentResolver.query(
        ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
        projection, selection, selectionArgs, sortOrder,
      )
      cursor?.use {
        var count = 0
        while (it.moveToNext() && count < maxResults) {
          contacts.add(mapOf(
            "name" to (it.getString(0) ?: ""),
            "phone" to (it.getString(1) ?: ""),
          ))
          count++
        }
      }
      Log.d(TAG, "Found ${contacts.size} contacts")
      mapOf("status" to "succeeded", "count" to contacts.size.toString(), "contacts" to contacts.toString())
    } catch (e: Exception) {
      Log.e(TAG, "Failed to read contacts", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to read contacts"))
    }
  }

  // ─── Photos ───

  suspend fun listPhotos(maxResults: Int): Map<String, Any> {
    sendProgress("Listing photos", inProgress = true, title = "List Photos")

    val photoPermission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      Manifest.permission.READ_MEDIA_IMAGES
    } else {
      Manifest.permission.READ_EXTERNAL_STORAGE
    }
    if (!ensurePermission(photoPermission, rationale = "Access photos")) {
      return mapOf("status" to "failed", "error" to "Photo permission denied")
    }

    return try {
      val projection = arrayOf(
        MediaStore.Images.Media._ID,
        MediaStore.Images.Media.DISPLAY_NAME,
        MediaStore.Images.Media.DATE_ADDED,
        MediaStore.Images.Media.SIZE,
      )
      val sortOrder = "${MediaStore.Images.Media.DATE_ADDED} DESC"

      val photos = mutableListOf<Map<String, String>>()
      val cursor = context.contentResolver.query(
        MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
        projection, null, null, sortOrder,
      )
      cursor?.use {
        var count = 0
        val sdf = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US)
        while (it.moveToNext() && count < maxResults) {
          val id = it.getLong(0)
          val uri = Uri.withAppendedPath(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id.toString())
          photos.add(mapOf(
            "name" to (it.getString(1) ?: ""),
            "date" to sdf.format(it.getLong(2) * 1000),
            "size_bytes" to (it.getLong(3).toString()),
            "uri" to uri.toString(),
          ))
          count++
        }
      }
      Log.d(TAG, "Found ${photos.size} photos")
      mapOf("status" to "succeeded", "count" to photos.size.toString(), "photos" to photos.toString())
    } catch (e: Exception) {
      Log.e(TAG, "Failed to list photos", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to list photos"))
    }
  }

  /**
   * Search photos by filename, album/folder, or date range. Any filter can be empty to skip it.
   *
   * @param query Substring to match in the photo filename (case-insensitive). Empty = any name.
   * @param album Album/folder name (BUCKET_DISPLAY_NAME), e.g. "Screenshots", "Camera". Empty = any.
   * @param dateFrom Inclusive start date as "yyyy-MM-dd". Empty = no lower bound.
   * @param dateTo Inclusive end date as "yyyy-MM-dd". Empty = no upper bound.
   * @param maxResults Max rows to return.
   */
  suspend fun searchPhotos(
    query: String,
    album: String,
    dateFrom: String,
    dateTo: String,
    maxResults: Int,
  ): Map<String, Any> {
    sendProgress("Searching photos", inProgress = true, title = "Search Photos",
      desc = listOf(query, album, dateFrom, dateTo).filter { it.isNotEmpty() }.joinToString(", ").ifEmpty { "all" })

    val photoPermission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      Manifest.permission.READ_MEDIA_IMAGES
    } else {
      Manifest.permission.READ_EXTERNAL_STORAGE
    }
    if (!ensurePermission(photoPermission, rationale = "Access photos")) {
      return mapOf("status" to "failed", "error" to "Photo permission denied")
    }

    return try {
      val selection = mutableListOf<String>()
      val selectionArgs = mutableListOf<String>()

      if (query.isNotEmpty()) {
        selection.add("${MediaStore.Images.Media.DISPLAY_NAME} LIKE ?")
        selectionArgs.add("%${query.replace("%", "").replace("_", "")}%")
      }
      if (album.isNotEmpty()) {
        selection.add("${MediaStore.Images.Media.BUCKET_DISPLAY_NAME} = ?")
        selectionArgs.add(album)
      }
      val dateParser = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { timeZone = TimeZone.getDefault() }
      if (dateFrom.isNotEmpty()) {
        val fromSecs = dateParser.parse(dateFrom)?.time?.div(1000)
          ?: return mapOf("status" to "failed", "error" to "Invalid dateFrom '$dateFrom' (expected yyyy-MM-dd)")
        selection.add("${MediaStore.Images.Media.DATE_ADDED} >= ?")
        selectionArgs.add(fromSecs.toString())
      }
      if (dateTo.isNotEmpty()) {
        // End of day: add 86400s so dateTo is inclusive.
        val toSecs = dateParser.parse(dateTo)?.time?.div(1000)?.plus(86400)
          ?: return mapOf("status" to "failed", "error" to "Invalid dateTo '$dateTo' (expected yyyy-MM-dd)")
        selection.add("${MediaStore.Images.Media.DATE_ADDED} < ?")
        selectionArgs.add(toSecs.toString())
      }

      val projection = arrayOf(
        MediaStore.Images.Media._ID,
        MediaStore.Images.Media.DISPLAY_NAME,
        MediaStore.Images.Media.DATE_ADDED,
        MediaStore.Images.Media.SIZE,
        MediaStore.Images.Media.BUCKET_DISPLAY_NAME,
      )
      val selectionStr = if (selection.isEmpty()) null else selection.joinToString(" AND ")
      val selectionArgsArr = if (selectionArgs.isEmpty()) null else selectionArgs.toTypedArray()
      val sortOrder = "${MediaStore.Images.Media.DATE_ADDED} DESC"

      val photos = mutableListOf<Map<String, String>>()
      val cursor = context.contentResolver.query(
        MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
        projection, selectionStr, selectionArgsArr, sortOrder,
      )
      cursor?.use {
        var count = 0
        val sdf = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US)
        while (it.moveToNext() && count < maxResults) {
          val id = it.getLong(0)
          val uri = Uri.withAppendedPath(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id.toString())
          photos.add(mapOf(
            "name" to (it.getString(1) ?: ""),
            "date" to sdf.format(it.getLong(2) * 1000),
            "size_bytes" to it.getLong(3).toString(),
            "album" to (it.getString(4) ?: ""),
            "uri" to uri.toString(),
          ))
          count++
        }
      }
      Log.d(TAG, "searchPhotos found ${photos.size} matches (selection=$selectionStr)")
      mapOf("status" to "succeeded", "count" to photos.size.toString(), "photos" to photos.toString())
    } catch (e: Exception) {
      Log.e(TAG, "Failed to search photos", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to search photos"))
    }
  }

  /**
   * Scan barcodes/QR codes from a photo using ML Kit (on-device).
   *
   * @param photoUri URI of the photo to scan (from listPhotos/searchPhotos).
   *                 If empty, scans the most recent photo in the gallery.
   */
  suspend fun scanBarcode(photoUri: String): Map<String, Any> {
    sendProgress("Scanning barcode", inProgress = true, title = "Scan Barcode",
      desc = if (photoUri.isEmpty()) "most recent photo" else photoUri.takeLast(40))

    val photoPermission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      Manifest.permission.READ_MEDIA_IMAGES
    } else {
      Manifest.permission.READ_EXTERNAL_STORAGE
    }
    if (!ensurePermission(photoPermission, rationale = "Access photos")) {
      return mapOf("status" to "failed", "error" to "Photo permission denied")
    }

    return try {
      // Resolve URI — fall back to most recent photo if empty.
      val uri: Uri = if (photoUri.isNotEmpty()) {
        Uri.parse(photoUri)
      } else {
        val projection = arrayOf(MediaStore.Images.Media._ID)
        val sortOrder = "${MediaStore.Images.Media.DATE_ADDED} DESC"
        context.contentResolver.query(
          MediaStore.Images.Media.EXTERNAL_CONTENT_URI, projection, null, null, sortOrder,
        )?.use { c ->
          if (c.moveToFirst()) {
            Uri.withAppendedPath(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, c.getLong(0).toString())
          } else null
        } ?: return mapOf("status" to "failed", "error" to "No photos found on device")
      }

      val image = com.google.mlkit.vision.common.InputImage.fromFilePath(context, uri)
      val scanner = com.google.mlkit.vision.barcode.BarcodeScanning.getClient()

      val barcodes = kotlinx.coroutines.suspendCancellableCoroutine<List<com.google.mlkit.vision.barcode.common.Barcode>> { cont ->
        scanner.process(image)
          .addOnSuccessListener { cont.resumeWith(Result.success(it)) }
          .addOnFailureListener { cont.resumeWith(Result.failure(it)) }
      }

      if (barcodes.isEmpty()) {
        return mapOf("status" to "succeeded", "count" to "0", "barcodes" to "[]",
          "message" to "No barcodes or QR codes found in the photo")
      }

      val results = barcodes.map { barcode ->
        mapOf(
          "format" to barcodeFormatName(barcode.format),
          "type" to barcodeTypeName(barcode.valueType),
          "value" to (barcode.rawValue ?: ""),
          "display" to (barcode.displayValue ?: ""),
        )
      }
      Log.d(TAG, "Scanned ${results.size} barcode(s) from $uri")
      mapOf("status" to "succeeded", "count" to results.size.toString(), "barcodes" to results.toString())
    } catch (e: Exception) {
      Log.e(TAG, "Failed to scan barcode", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to scan barcode"))
    }
  }

  private fun barcodeFormatName(format: Int): String = when (format) {
    com.google.mlkit.vision.barcode.common.Barcode.FORMAT_QR_CODE -> "QR_CODE"
    com.google.mlkit.vision.barcode.common.Barcode.FORMAT_EAN_13 -> "EAN_13"
    com.google.mlkit.vision.barcode.common.Barcode.FORMAT_EAN_8 -> "EAN_8"
    com.google.mlkit.vision.barcode.common.Barcode.FORMAT_UPC_A -> "UPC_A"
    com.google.mlkit.vision.barcode.common.Barcode.FORMAT_UPC_E -> "UPC_E"
    com.google.mlkit.vision.barcode.common.Barcode.FORMAT_CODE_39 -> "CODE_39"
    com.google.mlkit.vision.barcode.common.Barcode.FORMAT_CODE_93 -> "CODE_93"
    com.google.mlkit.vision.barcode.common.Barcode.FORMAT_CODE_128 -> "CODE_128"
    com.google.mlkit.vision.barcode.common.Barcode.FORMAT_PDF417 -> "PDF417"
    com.google.mlkit.vision.barcode.common.Barcode.FORMAT_AZTEC -> "AZTEC"
    com.google.mlkit.vision.barcode.common.Barcode.FORMAT_DATA_MATRIX -> "DATA_MATRIX"
    com.google.mlkit.vision.barcode.common.Barcode.FORMAT_ITF -> "ITF"
    com.google.mlkit.vision.barcode.common.Barcode.FORMAT_CODABAR -> "CODABAR"
    else -> "UNKNOWN"
  }

  private fun barcodeTypeName(type: Int): String = when (type) {
    com.google.mlkit.vision.barcode.common.Barcode.TYPE_URL -> "URL"
    com.google.mlkit.vision.barcode.common.Barcode.TYPE_EMAIL -> "EMAIL"
    com.google.mlkit.vision.barcode.common.Barcode.TYPE_PHONE -> "PHONE"
    com.google.mlkit.vision.barcode.common.Barcode.TYPE_SMS -> "SMS"
    com.google.mlkit.vision.barcode.common.Barcode.TYPE_WIFI -> "WIFI"
    com.google.mlkit.vision.barcode.common.Barcode.TYPE_GEO -> "GEO"
    com.google.mlkit.vision.barcode.common.Barcode.TYPE_CALENDAR_EVENT -> "CALENDAR_EVENT"
    com.google.mlkit.vision.barcode.common.Barcode.TYPE_CONTACT_INFO -> "CONTACT"
    com.google.mlkit.vision.barcode.common.Barcode.TYPE_PRODUCT -> "PRODUCT"
    com.google.mlkit.vision.barcode.common.Barcode.TYPE_TEXT -> "TEXT"
    com.google.mlkit.vision.barcode.common.Barcode.TYPE_ISBN -> "ISBN"
    else -> "UNKNOWN"
  }

  // ─── Apps ───

  suspend fun listApps(query: String): Map<String, Any> {
    sendProgress("Listing installed apps", inProgress = true, title = "List Apps", desc = "Query: ${query.ifEmpty { "all" }}")

    return try {
      val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
      val resolveInfos = context.packageManager.queryIntentActivities(intent, 0)

      val apps = resolveInfos
        .map { info ->
          mapOf(
            "name" to (info.loadLabel(context.packageManager)?.toString() ?: ""),
            "package_name" to info.activityInfo.packageName,
          )
        }
        .filter { app ->
          query.isEmpty() || app["name"]!!.contains(query, ignoreCase = true)
        }
        .distinctBy { it["package_name"] }
        .sortedBy { it["name"] }
        .take(50)

      Log.d(TAG, "Found ${apps.size} apps")
      mapOf("status" to "succeeded", "count" to apps.size.toString(), "apps" to apps.toString())
    } catch (e: Exception) {
      Log.e(TAG, "Failed to list apps", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to list apps"))
    }
  }

  suspend fun launchApp(packageName: String): Map<String, String> {
    sendProgress("Launching $packageName", inProgress = true, title = "Launch App", desc = packageName)

    return try {
      val intent = context.packageManager.getLaunchIntentForPackage(packageName.trim())
      if (intent != null) {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        Log.d(TAG, "Launched $packageName")
        mapOf("status" to "succeeded", "message" to "Launched $packageName")
      } else {
        mapOf("status" to "failed", "error" to "App not found: $packageName")
      }
    } catch (e: Exception) {
      Log.e(TAG, "Failed to launch app", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to launch app"))
    }
  }

  // ─── Phone Call ───

  suspend fun makePhoneCall(phoneNumber: String): Map<String, String> {
    sendProgress("Calling $phoneNumber", inProgress = true, title = "Phone Call", desc = "Number: $phoneNumber")

    if (!ensurePermission(Manifest.permission.CALL_PHONE, rationale = "Make phone calls")) {
      return mapOf("status" to "failed", "error" to "Phone permission denied")
    }

    return try {
      val intent = Intent(Intent.ACTION_CALL).apply {
        data = Uri.parse("tel:${phoneNumber.trim()}")
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      }
      context.startActivity(intent)
      mapOf("status" to "succeeded", "message" to "Calling $phoneNumber")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to make call", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to make call"))
    }
  }

  // ─── Set Alarm ───

  private suspend fun setAlarm(hour: Int, minute: Int, label: String): Map<String, String> {
    sendProgress("Setting alarm for $hour:${"%02d".format(minute)}", inProgress = true, title = "Set Alarm", desc = label)

    return try {
      val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
        putExtra(AlarmClock.EXTRA_HOUR, hour)
        putExtra(AlarmClock.EXTRA_MINUTES, minute)
        putExtra(AlarmClock.EXTRA_MESSAGE, label)
        putExtra(AlarmClock.EXTRA_SKIP_UI, true)
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      }
      context.startActivity(intent)
      mapOf("status" to "succeeded", "message" to "Alarm set for $hour:${"%02d".format(minute)} — $label")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to set alarm", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to set alarm"))
    }
  }

  // ─── Set Timer ───

  private suspend fun setTimer(durationSeconds: Int, label: String): Map<String, String> {
    sendProgress("Setting timer for ${durationSeconds}s", inProgress = true, title = "Set Timer", desc = label)

    return try {
      val intent = Intent(AlarmClock.ACTION_SET_TIMER).apply {
        putExtra(AlarmClock.EXTRA_LENGTH, durationSeconds)
        putExtra(AlarmClock.EXTRA_MESSAGE, label)
        putExtra(AlarmClock.EXTRA_SKIP_UI, true)
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      }
      context.startActivity(intent)
      mapOf("status" to "succeeded", "message" to "Timer set for ${durationSeconds}s — $label")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to set timer", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to set timer"))
    }
  }

  // ─── Get Location ───

  suspend fun getLocation(): Map<String, String> {
    sendProgress("Getting location", inProgress = true, title = "Get Location")

    if (!ensurePermission(Manifest.permission.ACCESS_FINE_LOCATION, rationale = "Access your location")) {
      return mapOf("status" to "failed", "error" to "Location permission denied")
    }

    return try {
      val locationManager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
      @Suppress("MissingPermission")
      val location = locationManager.getLastKnownLocation(LocationManager.GPS_PROVIDER)
        ?: locationManager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)

      if (location != null) {
        val result = mutableMapOf(
          "status" to "succeeded",
          "latitude" to location.latitude.toString(),
          "longitude" to location.longitude.toString(),
          "accuracy_meters" to location.accuracy.toString(),
        )
        // Try reverse geocode.
        try {
          @Suppress("DEPRECATION")
          val addresses = Geocoder(context, Locale.getDefault()).getFromLocation(location.latitude, location.longitude, 1)
          if (!addresses.isNullOrEmpty()) {
            val addr = addresses[0]
            result["address"] = addr.getAddressLine(0) ?: ""
            result["city"] = addr.locality ?: ""
            result["country"] = addr.countryName ?: ""
          }
        } catch (e: Exception) {
          Log.w(TAG, "Geocoder failed", e)
        }
        result
      } else {
        mapOf("status" to "failed", "error" to "Location not available. Ensure GPS is enabled.")
      }
    } catch (e: Exception) {
      Log.e(TAG, "Failed to get location", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to get location"))
    }
  }

  // ─── Open URL ───

  suspend fun openUrl(url: String): Map<String, String> {
    sendProgress("Opening URL", inProgress = true, title = "Open URL", desc = url)

    return try {
      val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      }
      context.startActivity(intent)
      mapOf("status" to "succeeded", "message" to "Opened $url")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to open URL", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to open URL"))
    }
  }

  // ─── Web Search ───

  suspend fun searchWeb(query: String): Map<String, String> {
    sendProgress("Searching: $query", inProgress = true, title = "Web Search", desc = query)

    return try {
      val intent = Intent(Intent.ACTION_WEB_SEARCH).apply {
        putExtra("query", query)
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      }
      context.startActivity(intent)
      mapOf("status" to "succeeded", "message" to "Searching for: $query")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to search web", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to search"))
    }
  }

  // ─── Clipboard ───

  suspend fun getClipboard(): Map<String, String> {
    sendProgress("Reading clipboard", inProgress = true, title = "Read Clipboard")

    return try {
      val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
      val clip = clipboard.primaryClip
      val text = if (clip != null && clip.itemCount > 0) {
        clip.getItemAt(0).coerceToText(context).toString()
      } else ""
      mapOf("status" to "succeeded", "content" to text)
    } catch (e: Exception) {
      Log.e(TAG, "Failed to read clipboard", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to read clipboard"))
    }
  }

  suspend fun setClipboard(text: String): Map<String, String> {
    sendProgress("Writing to clipboard", inProgress = true, title = "Set Clipboard")

    return try {
      val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
      val clip = ClipData.newPlainText("Mobile Claw", text)
      clipboard.setPrimaryClip(clip)
      mapOf("status" to "succeeded", "message" to "Copied to clipboard")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to set clipboard", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to set clipboard"))
    }
  }

  // ─── Device Info ───

  suspend fun getDeviceInfo(): Map<String, String> {
    sendProgress("Reading device info", inProgress = true, title = "Device Info")

    return try {
      val result = mutableMapOf<String, String>()

      // Battery.
      val batteryManager = context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
      val batteryLevel = batteryManager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
      val isCharging = batteryManager.isCharging
      result["battery_level"] = "$batteryLevel%"
      result["is_charging"] = isCharging.toString()

      // Storage.
      val stat = StatFs(Environment.getDataDirectory().path)
      val totalGb = (stat.totalBytes / (1024.0 * 1024.0 * 1024.0))
      val freeGb = (stat.availableBytes / (1024.0 * 1024.0 * 1024.0))
      result["storage_total_gb"] = "%.1f".format(totalGb)
      result["storage_free_gb"] = "%.1f".format(freeGb)

      // Connectivity.
      val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
      val network = connectivityManager.activeNetwork
      val capabilities = if (network != null) connectivityManager.getNetworkCapabilities(network) else null
      result["network_connected"] = (capabilities != null).toString()
      result["wifi"] = (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true).toString()
      result["cellular"] = (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true).toString()

      // Device.
      result["manufacturer"] = Build.MANUFACTURER
      result["model"] = Build.MODEL
      result["android_version"] = Build.VERSION.RELEASE
      result["sdk_version"] = Build.VERSION.SDK_INT.toString()

      result["status"] = "succeeded"
      result
    } catch (e: Exception) {
      Log.e(TAG, "Failed to get device info", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to get device info"))
    }
  }

  // ─── Share Content ───

  suspend fun shareContent(text: String, subject: String): Map<String, String> {
    sendProgress("Sharing content", inProgress = true, title = "Share", desc = subject)

    return try {
      val intent = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, text)
        if (subject.isNotEmpty()) putExtra(Intent.EXTRA_SUBJECT, subject)
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      }
      context.startActivity(Intent.createChooser(intent, "Share via").apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      })
      mapOf("status" to "succeeded", "message" to "Share dialog opened")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to share", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to share"))
    }
  }

  // ─── Flashlight ───

  suspend fun toggleFlashlight(turnOn: Boolean): Map<String, String> {
    sendProgress(if (turnOn) "Turning on flashlight" else "Turning off flashlight", inProgress = true, title = "Flashlight")

    return try {
      val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
      val cameraId = cameraManager.cameraIdList.firstOrNull()
        ?: return mapOf("status" to "failed", "error" to "No camera with flash found")
      cameraManager.setTorchMode(cameraId, turnOn)
      mapOf("status" to "succeeded", "message" to if (turnOn) "Flashlight on" else "Flashlight off")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to toggle flashlight", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to toggle flashlight"))
    }
  }

  // ─── Volume Control ───

  suspend fun setVolume(streamType: String, volumePercent: Int): Map<String, String> {
    sendProgress("Setting $streamType volume to $volumePercent%", inProgress = true, title = "Set Volume")

    return try {
      val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
      val stream = when (streamType.lowercase()) {
        "media", "music" -> AudioManager.STREAM_MUSIC
        "ring", "ringtone" -> AudioManager.STREAM_RING
        "alarm" -> AudioManager.STREAM_ALARM
        "notification" -> AudioManager.STREAM_NOTIFICATION
        else -> AudioManager.STREAM_MUSIC
      }
      val maxVol = audioManager.getStreamMaxVolume(stream)
      val targetVol = (maxVol * volumePercent.coerceIn(0, 100) / 100.0).toInt()
      audioManager.setStreamVolume(stream, targetVol, 0)
      mapOf("status" to "succeeded", "message" to "$streamType volume set to $volumePercent%")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to set volume", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to set volume"))
    }
  }

  // ─── Do Not Disturb ───

  suspend fun setDoNotDisturb(enable: Boolean): Map<String, String> {
    sendProgress(if (enable) "Enabling Do Not Disturb" else "Disabling Do Not Disturb", inProgress = true, title = "Do Not Disturb")

    return try {
      val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
      if (!notificationManager.isNotificationPolicyAccessGranted) {
        // Open DnD settings for user to grant.
        val intent = Intent(android.provider.Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS).apply {
          addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
        return mapOf("status" to "failed", "error" to "Please grant Do Not Disturb access in settings, then try again")
      }
      notificationManager.setInterruptionFilter(
        if (enable) NotificationManager.INTERRUPTION_FILTER_NONE
        else NotificationManager.INTERRUPTION_FILTER_ALL
      )
      mapOf("status" to "succeeded", "message" to if (enable) "Do Not Disturb enabled" else "Do Not Disturb disabled")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to set DnD", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to set Do Not Disturb"))
    }
  }

  // ─── Take Photo (via camera intent) ───

  suspend fun takePhoto(): Map<String, String> {
    sendProgress("Opening camera", inProgress = true, title = "Take Photo")

    return try {
      val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      }
      context.startActivity(intent)
      mapOf("status" to "succeeded", "message" to "Camera opened. Photo will be saved by the camera app.")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to open camera", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to open camera"))
    }
  }

  // ─── List Downloads ───

  suspend fun listDownloads(maxResults: Int): Map<String, Any> {
    sendProgress("Listing downloads", inProgress = true, title = "List Downloads")

    return try {
      val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
      val files = downloadsDir.listFiles()
        ?.sortedByDescending { it.lastModified() }
        ?.take(maxResults)
        ?.map { file ->
          mapOf(
            "name" to file.name,
            "size_bytes" to file.length().toString(),
            "date" to SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US).format(file.lastModified()),
            "path" to file.absolutePath,
          )
        } ?: listOf()

      mapOf("status" to "succeeded", "count" to files.size.toString(), "files" to files.toString())
    } catch (e: Exception) {
      Log.e(TAG, "Failed to list downloads", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to list downloads"))
    }
  }

  // ─── Open Settings ───

  suspend fun openSettings(settingsPage: String): Map<String, String> {
    sendProgress("Opening settings: $settingsPage", inProgress = true, title = "Open Settings")

    return try {
      val action = when (settingsPage.lowercase()) {
        "wifi" -> android.provider.Settings.ACTION_WIFI_SETTINGS
        "bluetooth" -> android.provider.Settings.ACTION_BLUETOOTH_SETTINGS
        "display" -> android.provider.Settings.ACTION_DISPLAY_SETTINGS
        "sound" -> android.provider.Settings.ACTION_SOUND_SETTINGS
        "battery" -> android.provider.Settings.ACTION_BATTERY_SAVER_SETTINGS
        "location" -> android.provider.Settings.ACTION_LOCATION_SOURCE_SETTINGS
        "security" -> android.provider.Settings.ACTION_SECURITY_SETTINGS
        "apps" -> android.provider.Settings.ACTION_APPLICATION_SETTINGS
        "notifications" -> android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS
        "accessibility" -> android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS
        "date" -> android.provider.Settings.ACTION_DATE_SETTINGS
        "language" -> android.provider.Settings.ACTION_LOCALE_SETTINGS
        "developer" -> android.provider.Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS
        else -> android.provider.Settings.ACTION_SETTINGS
      }
      val intent = Intent(action).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
      context.startActivity(intent)
      mapOf("status" to "succeeded", "message" to "Opened $settingsPage settings")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to open settings", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to open settings"))
    }
  }

  // ─── Create Reminder (via calendar with reminder alert) ───

  private suspend fun setReminder(title: String, dateTime: String, minutesBefore: Int): Map<String, String> {
    sendProgress("Setting reminder: $title", inProgress = true, title = "Set Reminder", desc = title)

    if (!ensurePermission(Manifest.permission.WRITE_CALENDAR, Manifest.permission.READ_CALENDAR,
        rationale = "Create reminders")) {
      return mapOf("status" to "failed", "error" to "Calendar permission denied")
    }

    return try {
      val startMillis = parseDateTimeLenient(dateTime) ?: return mapOf("status" to "failed", "error" to "Invalid date format: $dateTime")

      // Get default calendar.
      val calCursor = context.contentResolver.query(
        CalendarContract.Calendars.CONTENT_URI,
        arrayOf(CalendarContract.Calendars._ID),
        "${CalendarContract.Calendars.IS_PRIMARY} = 1",
        null, null,
      )
      val calId = calCursor?.use { if (it.moveToFirst()) it.getLong(0) else null } ?: 1L

      val values = ContentValues().apply {
        put(CalendarContract.Events.CALENDAR_ID, calId)
        put(CalendarContract.Events.TITLE, title)
        put(CalendarContract.Events.DTSTART, startMillis)
        put(CalendarContract.Events.DTEND, startMillis + 30 * 60 * 1000) // 30 min event
        put(CalendarContract.Events.HAS_ALARM, 1)
        put(CalendarContract.Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
      }
      val eventUri = context.contentResolver.insert(CalendarContract.Events.CONTENT_URI, values)
      val eventId = eventUri?.lastPathSegment?.toLongOrNull()

      // Add reminder alert.
      if (eventId != null) {
        val reminderValues = ContentValues().apply {
          put(CalendarContract.Reminders.EVENT_ID, eventId)
          put(CalendarContract.Reminders.MINUTES, minutesBefore)
          put(CalendarContract.Reminders.METHOD, CalendarContract.Reminders.METHOD_ALERT)
        }
        context.contentResolver.insert(CalendarContract.Reminders.CONTENT_URI, reminderValues)
      }

      mapOf("status" to "succeeded", "message" to "Reminder '$title' set for $dateTime (alert $minutesBefore min before)")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to set reminder", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to set reminder"))
    }
  }

  // ─── Calculator ───

  suspend fun calculate(expression: String): Map<String, String> {
    sendProgress("Calculating: $expression", inProgress = true, title = "Calculator", desc = expression)

    return try {
      val result = evaluateExpression(expression)
      mapOf("status" to "succeeded", "expression" to expression, "result" to result.toString())
    } catch (e: Exception) {
      Log.e(TAG, "Failed to calculate", e)
      mapOf("status" to "failed", "error" to "Invalid expression: ${e.message}")
    }
  }

  /**
   * Simple recursive-descent math expression evaluator.
   * Supports: +, -, *, /, %, ^, parentheses, and common functions (sqrt, abs, sin, cos, tan, log, ln, round, ceil, floor, pi, e).
   */
  internal fun evaluateExpression(expr: String): Double {
    val tokens = tokenize(expr)
    val parser = ExprParser(tokens)
    val result = parser.parseExpression()
    if (parser.pos < tokens.size) throw IllegalArgumentException("Unexpected token: ${tokens[parser.pos]}")
    return result
  }

  private fun tokenize(expr: String): List<String> {
    val tokens = mutableListOf<String>()
    var i = 0
    val s = expr.replace(" ", "")
    while (i < s.length) {
      val c = s[i]
      when {
        c.isDigit() || c == '.' -> {
          val start = i
          while (i < s.length && (s[i].isDigit() || s[i] == '.')) i++
          tokens.add(s.substring(start, i))
        }
        c.isLetter() -> {
          val start = i
          while (i < s.length && s[i].isLetter()) i++
          tokens.add(s.substring(start, i))
        }
        c in "+-*/%()" || c == '^' -> {
          tokens.add(c.toString())
          i++
        }
        else -> i++ // skip unknown
      }
    }
    return tokens
  }

  private class ExprParser(val tokens: List<String>) {
    var pos = 0
    fun peek(): String? = if (pos < tokens.size) tokens[pos] else null
    fun consume(): String = tokens[pos++]
    fun expect(t: String) { if (consume() != t) throw IllegalArgumentException("Expected $t") }

    fun parseExpression(): Double {
      var left = parseTerm()
      while (peek() == "+" || peek() == "-") {
        val op = consume()
        val right = parseTerm()
        left = if (op == "+") left + right else left - right
      }
      return left
    }

    fun parseTerm(): Double {
      var left = parsePower()
      while (peek() == "*" || peek() == "/" || peek() == "%") {
        val op = consume()
        val right = parsePower()
        left = when (op) {
          "*" -> left * right
          "/" -> left / right
          else -> left % right
        }
      }
      return left
    }

    fun parsePower(): Double {
      var base = parseUnary()
      while (peek() == "^") {
        consume()
        val exp = parseUnary()
        base = Math.pow(base, exp)
      }
      return base
    }

    fun parseUnary(): Double {
      if (peek() == "-") {
        consume()
        return -parseAtom()
      }
      if (peek() == "+") { consume() }
      return parseAtom()
    }

    fun parseAtom(): Double {
      val token = peek() ?: throw IllegalArgumentException("Unexpected end of expression")

      // Number literal.
      if (token[0].isDigit() || token[0] == '.') {
        consume()
        return token.toDouble()
      }

      // Constants.
      if (token == "pi") { consume(); return Math.PI }
      if (token == "e" && (pos + 1 >= tokens.size || tokens[pos + 1] != "(")) { consume(); return Math.E }

      // Function call: name(expr)
      if (token[0].isLetter()) {
        val name = consume()
        expect("(")
        val arg = parseExpression()
        expect(")")
        return when (name) {
          "sqrt" -> Math.sqrt(arg)
          "abs" -> Math.abs(arg)
          "sin" -> Math.sin(arg)
          "cos" -> Math.cos(arg)
          "tan" -> Math.tan(arg)
          "log" -> Math.log10(arg)
          "ln" -> Math.log(arg)
          "round" -> Math.round(arg).toDouble()
          "ceil" -> Math.ceil(arg)
          "floor" -> Math.floor(arg)
          "exp" -> Math.exp(arg)
          else -> throw IllegalArgumentException("Unknown function: $name")
        }
      }

      // Parenthesized expression.
      if (token == "(") {
        consume()
        val result = parseExpression()
        expect(")")
        return result
      }

      throw IllegalArgumentException("Unexpected token: $token")
    }
  }

  // ─── Fetch Web Content ───

  suspend fun fetchWebContent(url: String): Map<String, String> {
    sendProgress("Fetching: $url", inProgress = true, title = "Fetch URL", desc = url)

    return try {
      val connection = java.net.URL(url).openConnection() as java.net.HttpURLConnection
      connection.requestMethod = "GET"
      connection.setRequestProperty("User-Agent", "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36")
      connection.setRequestProperty("Accept", "text/html,application/xhtml+xml,*/*")
      connection.connectTimeout = 10_000
      connection.readTimeout = 15_000
      connection.instanceFollowRedirects = true

      val responseCode = connection.responseCode
      if (responseCode !in 200..299) {
        return mapOf("status" to "failed", "error" to "HTTP $responseCode")
      }

      val contentType = connection.contentType ?: ""
      val rawBody = connection.inputStream.bufferedReader().use { it.readText() }
      connection.disconnect()

      // Extract readable text from HTML.
      val body = if (contentType.contains("html", ignoreCase = true)) {
        extractTextFromHtml(rawBody)
      } else {
        rawBody
      }

      // Truncate to keep context window manageable for on-device LLM.
      val truncated = if (body.length > 4000) body.take(4000) + "\n...[truncated]" else body

      mapOf(
        "status" to "succeeded",
        "url" to url,
        "content_type" to contentType,
        "content" to truncated,
        "content_length" to body.length.toString(),
      )
    } catch (e: Exception) {
      Log.e(TAG, "Failed to fetch URL", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to fetch URL"))
    }
  }

  /**
   * Basic HTML-to-text: strips tags, decodes common entities, collapses whitespace.
   */
  internal fun extractTextFromHtml(html: String): String {
    // Remove script/style/nav/footer/header blocks — they are noise for content extraction.
    var text = html.replace(
      Regex(
        "<(script|style|nav|footer|header|aside|form)[^>]*>[\\s\\S]*?</\\1>",
        RegexOption.IGNORE_CASE,
      ),
      "",
    )
    // Prefer <main> / <article> / role="main" content if present.
    val mainMatch = Regex(
      "<(main|article)\\b[^>]*>([\\s\\S]*?)</\\1>",
      RegexOption.IGNORE_CASE,
    ).find(text)
    if (mainMatch != null) {
      text = mainMatch.groupValues[2]
    }
    // Convert block-level tags and table rows to newlines so content doesn't all smash together.
    text = text.replace(
      Regex("<(br|p|div|li|h[1-6]|tr|section)[^>]*/?>", RegexOption.IGNORE_CASE),
      "\n",
    )
    // Collapse <td>/<th> to a tab so table rows remain scannable.
    text = text.replace(Regex("<(td|th)[^>]*/?>", RegexOption.IGNORE_CASE), "\t")
    // Strip remaining tags.
    text = text.replace(Regex("<[^>]+>"), " ")
    // Decode common entities.
    text = text.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
      .replace("&quot;", "\"").replace("&#39;", "'").replace("&nbsp;", " ")
    // Collapse whitespace per line (preserve newlines).
    text = text.lineSequence()
      .map { it.replace(Regex("[ \\t]+"), " ").trim() }
      .filter { it.isNotEmpty() }
      .joinToString("\n")

    // Drop nav-menu runs: only filter short lines when they appear in a run of 3+ consecutive
    // short, non-sentence lines. Real nav menus have multiple items in sequence; isolated short
    // lines in prose content are kept. This stops the filter from destroying simple content.
    val lines = text.lines()
    fun isNavLike(line: String): Boolean {
      if (line.length >= 50) return false
      if (line.any { it in ".?!:" } && line.length >= 20) return false
      // Short lines with weather/temperature signals are data, not nav.
      if (Regex("""[-+]?\d+\s*(?:°|°c|°f|%|km/h|mph|mm|in)\b""", RegexOption.IGNORE_CASE)
          .containsMatchIn(line)
      ) return false
      return true
    }
    // Only activate the nav-run filter on substantial pages (≥8 lines). Small fragments are never
    // nav menus, and the filter would destroy them.
    val kept = if (lines.size < 8) {
      lines
    } else {
      val navRunStart = IntArray(lines.size)
      var run = 0
      for (idx in lines.indices) {
        run = if (isNavLike(lines[idx])) run + 1 else 0
        navRunStart[idx] = run
      }
      val dropMask = BooleanArray(lines.size)
      for (idx in lines.indices) {
        if (navRunStart[idx] >= 4) {
          val end = idx
          var start = idx
          while (start > 0 && navRunStart[start - 1] >= 1) start--
          for (j in start..end) dropMask[j] = true
        }
      }
      for (k in lines.indices) {
        if (dropMask[k] && k + 1 < lines.size && isNavLike(lines[k + 1])) dropMask[k + 1] = true
      }
      lines.filterIndexed { idx, _ -> !dropMask[idx] }
    }
    return kept.joinToString("\n").replace(Regex("\\n{3,}"), "\n\n").trim()
  }

  /**
   * Heuristic: detect fetched pages that are blocked/gated/empty and shouldn't be fed into the
   * formatter. Weather/news sites commonly reject simple HTTP clients with Cloudflare/Akamai
   * challenges or return a tiny JS shell.
   */
  private fun isUnusablePageContent(content: String): Boolean {
    if (content.isBlank()) return true
    if (content.length < 400) return true
    val lower = content.lowercase()
    val blockSignals = listOf(
      "access denied",
      "attention required",
      "checking your browser",
      "enable javascript",
      "please enable js",
      "cloudflare",
      "request unsuccessful. incapsula",
      "verify you are a human",
      "bot protection",
      "403 forbidden",
    )
    if (blockSignals.any { it in lower }) return true
    // Require at least some alphabetic prose — very low alpha-char ratio usually means it's
    // mostly nav markup / whitespace.
    val alphaCount = content.count { it.isLetter() }
    if (alphaCount < content.length / 4) return true
    return false
  }

  /** Strip HTML tags and decode common entities from a short fragment (e.g. a search snippet). */
  private fun stripHtmlTags(fragment: String): String {
    var text = fragment.replace(Regex("<[^>]+>"), "")
    text = text.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
      .replace("&quot;", "\"").replace("&#39;", "'").replace("&nbsp;", " ")
    text = text.replace(Regex("\\s+"), " ")
    return text
  }

  // ─── Check Internet Connection ───

  suspend fun checkInternet(): Map<String, String> {
    return try {
      val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
      val network = connectivityManager.activeNetwork
      val capabilities = if (network != null) connectivityManager.getNetworkCapabilities(network) else null

      val connected = capabilities != null
      val wifi = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
      val cellular = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true
      val hasInternet = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
      val validated = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true

      val connectionType = when {
        wifi -> "WiFi"
        cellular -> "Cellular"
        connected -> "Other"
        else -> "None"
      }

      mapOf(
        "status" to "succeeded",
        "connected" to connected.toString(),
        "connection_type" to connectionType,
        "has_internet" to hasInternet.toString(),
        "validated" to validated.toString(),
        "summary" to if (validated) "Connected to internet via $connectionType" else if (connected) "Connected to $connectionType but no internet access" else "No internet connection",
      )
    } catch (e: Exception) {
      Log.e(TAG, "Failed to check internet", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Failed to check internet"))
    }
  }

  // ─── Web Search (returns results) ───

  suspend fun webSearch(query: String): Map<String, String> {
    sendProgress("Searching: $query", inProgress = true, title = "Web Search", desc = query)

    return try {
      val encodedQuery = java.net.URLEncoder.encode(query, "UTF-8")

      // DuckDuckGo only — Google returns a consent/redirect stub to mobile scrapers that
      // defeats our HTML parser. DDG lite works reliably.
      val results = searchDuckDuckGo(encodedQuery)
      val source = "duckduckgo"

      if (isUnusableSearchResult(results)) {
        return mapOf("status" to "failed", "error" to "No search results found for: $query")
      }

      // Auto-fetch the top 2 result URLs so the caller gets actual page content, not just
      // titles/snippets. DuckDuckGo returns links and one-line blurbs — without this, downstream
      // evaluation/formatting has nothing substantive to work with.
      // Auto-fetch page content: try up to 3 top URLs, skip junk (blocked/empty/tiny),
      // keep the first usable one. Many weather/news sites block simple HTTP clients or
      // return JS-only shells — hence the fallback chain.
      val candidateUrls = Regex("""https?://[^\s]+""")
        .findAll(results)
        .map { it.value.trimEnd('.', ',', ')', ']') }
        .map { it.replace("&amp;", "&") }
        .filter { !it.contains("duckduckgo.com") }
        .distinct()
        .take(3)
        .toList()

      Log.d(TAG, "webSearch: candidate URLs: $candidateUrls")
      val pageContent = StringBuilder()
      for ((i, url) in candidateUrls.withIndex()) {
        try {
          val fetched = fetchWebContent(url)
          val status = fetched["status"]
          val content = fetched["content"] ?: ""
          val usable = status == "succeeded" && !isUnusablePageContent(content)
          Log.d(TAG, "webSearch auto-fetch #${i + 1} $url -> status=$status, content=${content.length} chars, usable=$usable")
          if (status == "succeeded") {
            Log.d(TAG, "  content head: ${content.take(300).replace("\n", " | ")}")
          }
          if (!usable) continue
          pageContent.append("\n--- Page content from $url ---\n")
          pageContent.append(content.take(1500))
          pageContent.append("\n")
          break  // one good page is enough for the 2B formatter
        } catch (e: Exception) {
          Log.w(TAG, "Auto-fetch failed for $url: ${e.message}")
        }
      }

      // Keep only the first 5 search result entries to save tokens for fetched content.
      val trimmedResults = results.lineSequence()
        .take(25)  // ~5 results × 4-5 lines each
        .joinToString("\n")
      val combined = if (pageContent.isNotEmpty()) "$trimmedResults\n$pageContent" else results
      val truncated = if (combined.length > 4000) combined.take(4000) + "\n...[truncated]" else combined

      mapOf(
        "status" to "succeeded",
        "query" to query,
        "source" to source,
        "results" to truncated,
      )
    } catch (e: Exception) {
      Log.e(TAG, "Failed to web search", e)
      mapOf("status" to "failed", "error" to (e.message ?: "Web search failed"))
    }
  }

  /**
   * Google sometimes returns a consent / "click here if not redirected" stub instead of real
   * results. Treat such pages, and anything suspiciously short, as unusable so we can fall back.
   */
  private fun isUnusableSearchResult(text: String): Boolean {
    if (text.isBlank()) return true
    if (text.length < 120) return true
    val lower = text.lowercase()
    val stubSignals = listOf(
      "click here if you are not redirected",
      "enable javascript",
      "before you continue",
      "our systems have detected unusual traffic",
      "sorry, we can't verify",
    )
    return stubSignals.any { lower.contains(it) }
  }

  /**
   * Search via Google HTML and parse results.
   */
  private fun searchGoogle(encodedQuery: String): String {
    return try {
      val url = "https://www.google.com/search?q=$encodedQuery&hl=en&num=8"
      val connection = java.net.URL(url).openConnection() as java.net.HttpURLConnection
      connection.requestMethod = "GET"
      connection.setRequestProperty("User-Agent", "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36")
      connection.setRequestProperty("Accept", "text/html,application/xhtml+xml,*/*")
      connection.setRequestProperty("Accept-Language", "en-US,en;q=0.9")
      connection.connectTimeout = 10_000
      connection.readTimeout = 15_000
      connection.instanceFollowRedirects = true

      val responseCode = connection.responseCode
      if (responseCode !in 200..299) {
        Log.w(TAG, "Google search HTTP $responseCode")
        return ""
      }

      val html = connection.inputStream.bufferedReader().use { it.readText() }
      connection.disconnect()

      Log.d(TAG, "Google HTML length: ${html.length}")
      extractGoogleResults(html)
    } catch (e: Exception) {
      Log.w(TAG, "Google search failed: ${e.message}")
      ""
    }
  }

  /**
   * Extract search results from Google HTML.
   */
  internal fun extractGoogleResults(html: String): String {
    val results = StringBuilder()

    // Pattern 1: Match <a href="/url?q=ACTUAL_URL"><h3>Title</h3></a> (Google redirected links)
    val redirectPattern = Regex("""<a[^>]*href="/url\?q=([^&"]+)[^"]*"[^>]*>.*?<h3[^>]*>(.*?)</h3>""", RegexOption.DOT_MATCHES_ALL)
    val redirectMatches = redirectPattern.findAll(html).toList()

    if (redirectMatches.isNotEmpty()) {
      for (i in redirectMatches.indices.take(8)) {
        val rawUrl = java.net.URLDecoder.decode(redirectMatches[i].groupValues[1], "UTF-8")
        val title = redirectMatches[i].groupValues[2].replace(Regex("<[^>]+>"), "").trim()
        if (title.isNotEmpty() && rawUrl.startsWith("http")) {
          results.append("${results.toString().count { it == '\n' } / 3 + 1}. $title\n   $rawUrl\n\n")
        }
      }
    }

    // Pattern 2: Match direct <a href="https://..."><h3>Title</h3></a>
    if (results.isEmpty()) {
      val directPattern = Regex("""<a[^>]*href="(https?://[^"]+)"[^>]*>.*?<h3[^>]*>(.*?)</h3>""", RegexOption.DOT_MATCHES_ALL)
      val directMatches = directPattern.findAll(html).toList()
      for (i in directMatches.indices.take(8)) {
        val url = directMatches[i].groupValues[1]
        val title = directMatches[i].groupValues[2].replace(Regex("<[^>]+>"), "").trim()
        if (title.isNotEmpty() && !url.contains("google.com")) {
          results.append("${i + 1}. $title\n   $url\n\n")
        }
      }
    }

    // Pattern 3: Try extracting from data attributes (Google sometimes uses data-href)
    if (results.isEmpty()) {
      val dataPattern = Regex("""data-href="(https?://[^"]+)"[^>]*>.*?<h3[^>]*>(.*?)</h3>""", RegexOption.DOT_MATCHES_ALL)
      val dataMatches = dataPattern.findAll(html).toList()
      for (i in dataMatches.indices.take(8)) {
        val url = dataMatches[i].groupValues[1]
        val title = dataMatches[i].groupValues[2].replace(Regex("<[^>]+>"), "").trim()
        if (title.isNotEmpty()) {
          results.append("${i + 1}. $title\n   $url\n\n")
        }
      }
    }

    if (results.isEmpty()) {
      // Last resort: extract any readable text from the page
      val text = extractTextFromHtml(html)
      if (text.length > 100) {
        return text.take(2000)
      }
    }

    return results.toString().trim()
  }

  /**
   * Search via DuckDuckGo HTML Lite (fallback).
   */
  private fun searchDuckDuckGo(encodedQuery: String): String {
    return try {
      val url = "https://lite.duckduckgo.com/lite/"
      val connection = java.net.URL(url).openConnection() as java.net.HttpURLConnection
      connection.requestMethod = "POST"
      connection.doOutput = true
      connection.setRequestProperty("User-Agent", "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36")
      connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
      connection.setRequestProperty("Accept", "text/html")
      connection.connectTimeout = 10_000
      connection.readTimeout = 15_000
      connection.instanceFollowRedirects = true

      connection.outputStream.use { os ->
        os.write("q=$encodedQuery".toByteArray(Charsets.UTF_8))
      }

      val responseCode = connection.responseCode
      if (responseCode !in 200..299) {
        Log.w(TAG, "DuckDuckGo search HTTP $responseCode")
        return ""
      }

      val html = connection.inputStream.bufferedReader().use { it.readText() }
      connection.disconnect()

      extractDuckDuckGoResults(html)
    } catch (e: Exception) {
      Log.w(TAG, "DuckDuckGo search failed: ${e.message}")
      ""
    }
  }

  /**
   * Extract search results from DuckDuckGo lite HTML.
   */
  internal fun extractDuckDuckGoResults(html: String): String {
    val results = StringBuilder()
    val linkPattern = Regex("""<a[^>]*href=["']([^"']+)["'][^>]*class=['"]result-link['"][^>]*>([^<]+)</a>""")
    val snippetPattern = Regex("""<td[^>]*class=['"]result-snippet['"][^>]*>(.*?)</td>""", RegexOption.DOT_MATCHES_ALL)

    val links = linkPattern.findAll(html).toList()
    val snippets = snippetPattern.findAll(html).toList()

    for (i in links.indices.take(8)) {
      val url = links[i].groupValues[1]
      val title = stripHtmlTags(links[i].groupValues[2]).trim()
      val rawSnippet = snippets.getOrNull(i)?.groupValues?.get(1) ?: ""
      val snippet = stripHtmlTags(rawSnippet).trim()
      results.append("${i + 1}. $title\n   $url\n   $snippet\n\n")
    }

    if (results.isEmpty()) {
      return extractTextFromHtml(html).take(2000)
    }

    return results.toString().trim()
  }

  /**
   * Lenient date-time parser that handles common LLM malformations.
   * Attempts multiple strategies to extract a valid date from garbled input.
   * Returns epoch millis or null.
   */
  internal fun parseDateTimeLenient(input: String): Long? {
    val trimmed = input.trim()
    Log.d(TAG, "parseDateTimeLenient input: '$trimmed'")

    // Strategy 1: Try exact ISO format first.
    val exactFormats = listOf(
      "yyyy-MM-dd'T'HH:mm",
      "yyyy-MM-dd'T'HH:mm:ss",
      "yyyy-MM-dd HH:mm",
      "yyyy-MM-dd HH:mm:ss",
      "yyyy/MM/dd'T'HH:mm",
      "yyyy/MM/dd HH:mm",
      "MM/dd/yyyy HH:mm",
      "MM-dd-yyyy HH:mm",
    )
    for (fmt in exactFormats) {
      try {
        val sdf = SimpleDateFormat(fmt, Locale.US)
        sdf.timeZone = TimeZone.getDefault()
        sdf.isLenient = false
        val result = sdf.parse(trimmed)?.time
        if (result != null) {
          Log.d(TAG, "Parsed with format '$fmt': $result")
          return result
        }
      } catch (_: Exception) {}
    }

    // Strategy 2: Extract digits and reconstruct. Handle garbled outputs like "2066406T15:00".
    // Try to find a pattern: 4-digit year, 1-2 digit month, 1-2 digit day, then time.
    val digitTimeRegex = Regex("""(\d{4})-?(\d{1,2})-?(\d{1,2})[T\s]+(\d{1,2}):(\d{2})(?::(\d{2}))?""")
    digitTimeRegex.find(trimmed)?.let { match ->
      try {
        val year = match.groupValues[1].toInt()
        val month = match.groupValues[2].toInt()
        val day = match.groupValues[3].toInt()
        val hour = match.groupValues[4].toInt()
        val minute = match.groupValues[5].toInt()
        if (month in 1..12 && day in 1..31 && hour in 0..23 && minute in 0..59) {
          val cal = java.util.Calendar.getInstance()
          cal.set(year, month - 1, day, hour, minute, 0)
          cal.set(java.util.Calendar.MILLISECOND, 0)
          Log.d(TAG, "Parsed via digit extraction: ${cal.time}")
          return cal.timeInMillis
        }
      } catch (_: Exception) {}
    }

    // Strategy 3: Handle concatenated date digits like "20260406" + time.
    val concatRegex = Regex("""(\d{8})[T\s]+(\d{1,2}):(\d{2})""")
    concatRegex.find(trimmed)?.let { match ->
      try {
        val dateStr = match.groupValues[1]
        val year = dateStr.substring(0, 4).toInt()
        val month = dateStr.substring(4, 6).toInt()
        val day = dateStr.substring(6, 8).toInt()
        val hour = match.groupValues[2].toInt()
        val minute = match.groupValues[3].toInt()
        if (month in 1..12 && day in 1..31 && hour in 0..23 && minute in 0..59) {
          val cal = java.util.Calendar.getInstance()
          cal.set(year, month - 1, day, hour, minute, 0)
          cal.set(java.util.Calendar.MILLISECOND, 0)
          Log.d(TAG, "Parsed via concat extraction: ${cal.time}")
          return cal.timeInMillis
        }
      } catch (_: Exception) {}
    }

    // Strategy 4: Just try lenient parsing as last resort.
    try {
      val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm", Locale.US)
      sdf.timeZone = TimeZone.getDefault()
      sdf.isLenient = true
      val result = sdf.parse(trimmed)?.time
      if (result != null) {
        Log.d(TAG, "Parsed with lenient mode: $result")
        return result
      }
    } catch (_: Exception) {}

    Log.w(TAG, "Failed to parse date-time: '$trimmed'")
    return null
  }
}
