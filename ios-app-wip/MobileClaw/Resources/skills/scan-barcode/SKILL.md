---
name: scan-barcode
description: Scan barcodes or QR codes from a photo in the device gallery using on-device ML Kit.
---

# Scan Barcode

## Instructions

Call the `scan_barcode` tool with:
- photoUri: the URI of the photo to scan (obtained from list-photos or search-photos). Pass an empty string to scan the most recent photo in the gallery.

Returns detected barcodes. Each barcode includes:
- format: QR_CODE, EAN_13, CODE_128, etc.
- type: URL, EMAIL, PHONE, SMS, WIFI, TEXT, CONTACT, CALENDAR_EVENT, etc.
- value: the raw decoded string
- display: human-readable version

Common chains:
- "What's in the QR code I just photographed?" → list-photos (maxResults=1) → scan-barcode (with that URI)
- "Read all QR codes from my Screenshots" → search-photos (album="Screenshots") → scan-barcode (one per photo)
