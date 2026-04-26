---
name: fetch-web-content
description: Fetch and read the text content of a web page URL.
---

# Fetch Web Content

## Instructions

Call the `fetch_web_content` tool with:
- url: the full URL to fetch (e.g. "https://example.com/page")

Returns the text content of the page (HTML is converted to readable text). Content is truncated to 4000 characters for context efficiency.

Use this after `search_web` to read a specific result page, or when the user provides a URL and wants its content.
