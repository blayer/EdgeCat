---
name: search-photos
description: Search photos in the device gallery by filename, album/folder, or date range.
---

# Search Photos

## Instructions

Call the `search_photos` tool with any combination of these filters (empty string = ignore that filter):
- query: substring to match in the filename, case-insensitive (e.g. "screenshot", "IMG_2025")
- album: folder/album name (e.g. "Screenshots", "Camera", "Downloads")
- dateFrom: inclusive start date in yyyy-MM-dd format (e.g. "2025-06-01")
- dateTo: inclusive end date in yyyy-MM-dd format (e.g. "2025-06-30")
- maxResults: maximum number of photos to return (e.g. "20")

Examples:
- Find screenshots from last week: album="Screenshots", dateFrom="2025-06-01", dateTo="2025-06-07"
- Find photos with "vacation" in the name: query="vacation"
- Find all camera photos from yesterday: album="Camera", dateFrom="2025-06-10", dateTo="2025-06-10"

Returns a list of matching photos with name, date, size, album, and URI.
