# Orchestration On-Device Test Plan

Scenarios for testing orchestration (plan → execute → evaluate), save-as-skill, and auto-repair.

## Orchestration Scenarios

| # | Scenario | Skills | Test Prompt | Pass Pattern | Timeout |
|---|----------|--------|-------------|-------------|---------|
| 1 | single-native-skill | (none) | What is 42 times 17? | Goal achieved | 90 |
| 2 | two-skill-chain | (none) | Get my device info and calculate the hash of the manufacturer name | Goal achieved | 180 |
| 3 | web-and-summarize | (none) | Search the web for latest Android news and summarize it | Goal achieved | 240 |
| 4 | reminder-test | (none) | Set a reminder for tomorrow at 9am to buy groceries | Goal achieved | 120 |
| 5 | multi-step-plan | (none) | Look up the weather in Tokyo and copy the summary to clipboard | Goal achieved | 240 |

## Auto-Repair Scenarios

| # | Scenario | Skills | Test Prompt | Pass Pattern | Timeout |
|---|----------|--------|-------------|-------------|---------|
| 6 | repair-fallback | (none) | Create a calendar event for tomorrow at 3pm called Team Meeting | Goal achieved | 300 |

## JS Skill Scenarios

| # | Scenario | Skills | Test Prompt | Pass Pattern | Timeout |
|---|----------|--------|-------------|-------------|---------|
| 7 | js-qr-code | qr-code | Generate a QR code for https://example.com | Called JS script | 120 |
| 8 | js-text-spinner | text-spinner | Spin this text: Hello World | Called JS script | 120 |
