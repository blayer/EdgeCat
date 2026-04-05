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
import kotlinx.coroutines.channels.SendChannel
import java.io.File
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

  // ─── Set Alarm ───

  suspend fun setAlarm(hour: Int, minute: Int, label: String): Map<String, String> {
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

  suspend fun setTimer(durationSeconds: Int, label: String): Map<String, String> {
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

  suspend fun setReminder(title: String, dateTime: String, minutesBefore: Int): Map<String, String> {
    sendProgress("Setting reminder: $title", inProgress = true, title = "Set Reminder", desc = title)

    if (!ensurePermission(Manifest.permission.WRITE_CALENDAR, Manifest.permission.READ_CALENDAR,
        rationale = "Create reminders")) {
      return mapOf("status" to "failed", "error" to "Calendar permission denied")
    }

    return try {
      val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm", Locale.US)
      sdf.timeZone = TimeZone.getDefault()
      val startMillis = sdf.parse(dateTime)?.time ?: return mapOf("status" to "failed", "error" to "Invalid date")

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
}
