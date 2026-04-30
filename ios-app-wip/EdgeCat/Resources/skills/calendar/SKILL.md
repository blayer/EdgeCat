---
name: calendar
description: Create, read, edit, and delete calendar events and reminders on the device.
---

# Calendar

## Instructions

Call the `manage_calendar` tool with an `action` and the required parameters for that action.

Actions:
- **create**: Create a calendar event. Params: `title`, `startDateTime` (yyyy-MM-ddTHH:mm), `endDateTime` (yyyy-MM-ddTHH:mm), `location` (optional), `description` (optional), `reminderMinutes` (optional, adds alert).
- **read**: Read calendar events in a date range. Params: `startDate` (yyyy-MM-dd), `endDate` (yyyy-MM-dd).
- **edit**: Edit an existing event. Params: `eventId` or `originalTitle` (to find by name), plus any fields to update: `title`, `startDateTime`, `endDateTime`, `location`, `description`.
- **delete**: Delete an event. Params: `eventId` or `title` (to find by name).
