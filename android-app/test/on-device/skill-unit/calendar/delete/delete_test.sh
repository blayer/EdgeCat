SETUP_CMD='NOW_MS=$(python3 -c "import time; print(int(time.time()*1000))") && END_MS=$((NOW_MS + 3600000)) && $ADB shell "content insert --uri content://com.android.calendar/events --bind title:s:DeleteMe --bind dtstart:l:$NOW_MS --bind dtend:l:$END_MS --bind calendar_id:i:1 --bind eventTimezone:s:UTC"'
PROMPT="Delete the calendar event called DeleteMe"
PASS_PATTERN="Task complete"
TIMEOUT=20
