---
name: timer
description: Set, show, and dismiss alarms and timers on the device.
---

# Timer

## Instructions

Call the `manage_timer` tool with an `action` and the required parameters for that action.

Actions:
- **set_alarm**: Set an alarm. Params: `hour` (0-23), `minute` (0-59), `label`.
- **set_timer**: Set a countdown timer. Params: `durationSeconds`, `label`.
- **show_alarms**: Open the device clock app to show all alarms. No params.
- **dismiss_alarm**: Dismiss a ringing alarm. Params: `label` (optional, to match a specific alarm).
