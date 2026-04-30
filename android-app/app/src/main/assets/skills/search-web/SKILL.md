---
name: search-web
description: Search the web and return up to 8 results with title, URL, and snippet — a LINK LIST, not the answer. For ANSWERING a question (weather, news, facts) chain with fetch-web-content on the top result's URL.
---

# Search Web

## Instructions

Call the `run_js` tool using `index.html` and a JSON string for `data` with the following fields:
- **query**: Required. The search query text. Extract clear search keywords from the user's request.

Returns up to 8 search results (title, URL, snippet). The output is a link list — it does NOT contain the actual page content. For ANSWERING a question (weather, news, facts), you MUST chain `fetch-web-content` on the top result's URL so the formatter has the actual page text to extract from.

**Constraints:**
- Keep the query concise and keyword-focused for best results.
- If the user asks about current events, include the year in the query.
