package com.mobileclaw.app.customtasks.agentchat

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.CalendarContract
import android.provider.ContactsContract
import android.provider.MediaStore
import android.telephony.SmsManager
import android.util.Log
import androidx.core.content.ContextCompat
import com.mobileclaw.app.common.AgentAction
import com.mobileclaw.app.common.RequestPermissionAgentAction
import com.mobileclaw.app.common.SkillProgressAgentAction
import kotlinx.coroutines.channels.SendChannel
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

private const val TAG = "AGDeviceSkills"

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
    return action.result.await()
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

  // ─── Calendar: Read ───

  suspend fun readCalendarEvents(startDate: String, endDate: String): Map<String, Any> {
    sendProgress("Reading calendar events", inProgress = true, title = "Read Calendar", desc = "$startDate to $endDate")

    if (!ensurePermission(Manifest.permission.READ_CALENDAR, rationale = "Read calendar events")) {
      return mapOf("status" to "failed", "error" to "Calendar permission denied")
    }

    return try {
      val sdf = SimpleDateFormat("yyyy-MM-dd", Locale.US)
      sdf.timeZone = TimeZone.getDefault()
      val startMillis = sdf.parse(startDate)?.time ?: return mapOf("status" to "failed", "error" to "Invalid start date")
      val endCal = Calendar.getInstance().apply { time = sdf.parse(endDate) ?: return mapOf("status" to "failed", "error" to "Invalid end date") }
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

  // ─── Calendar: Write ───

  suspend fun createCalendarEvent(
    title: String, startDateTime: String, endDateTime: String, location: String, description: String,
  ): Map<String, String> {
    sendProgress("Creating calendar event: $title", inProgress = true, title = "Create Event", desc = title)

    if (!ensurePermission(Manifest.permission.WRITE_CALENDAR, Manifest.permission.READ_CALENDAR,
        rationale = "Create calendar events")) {
      return mapOf("status" to "failed", "error" to "Calendar permission denied")
    }

    return try {
      val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm", Locale.US)
      sdf.timeZone = TimeZone.getDefault()
      val startMillis = sdf.parse(startDateTime)?.time ?: return mapOf("status" to "failed", "error" to "Invalid start date")
      val endMillis = sdf.parse(endDateTime)?.time ?: return mapOf("status" to "failed", "error" to "Invalid end date")

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
}
