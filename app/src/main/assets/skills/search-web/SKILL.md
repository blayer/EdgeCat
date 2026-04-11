---
name: search-web
description: Search the web and return text results with titles, URLs, and snippets.
---

# Search Web

## Instructions

Call the `run_js` tool using `index.html` and a JSON string for `data` with the following fields:
- **query**: Required. The search query text. Extract clear search keywords from the user's request.

Returns up to 8 search results with title, URL, and snippet for each. Use `fetch-web-content` to read the full content of any result URL.

**Constraints:**
- Keep the query concise and keyword-focused for best results.
- If the user asks about current events, include the year in the query.
