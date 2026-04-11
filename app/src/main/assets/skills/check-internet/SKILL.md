---
name: check-internet
description: Check if the device has an active internet connection and what type (WiFi, cellular, etc). Should be called before any plan step that requires internet access (e.g., web search, fetching web content, sending email).
---

# Check Internet

## When to Use

Call this skill as the **first step** in any plan that includes internet-dependent actions such as:
- Searching the web
- Fetching web page content
- Sending emails or SMS
- Any network request

If the check reports no connection, inform the user instead of attempting network calls that will fail.

## Instructions

Call the `check_internet` tool with no arguments.

Returns connection status, type (wifi/cellular), and whether the connection can actually reach the internet.
