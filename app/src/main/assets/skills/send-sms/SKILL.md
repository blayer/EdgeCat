---
name: send-sms
description: Send an SMS text message directly to a phone number on this device.
---

# Send SMS

## Instructions

Call the `send_sms` tool with:
- phoneNumber: the phone number to send to (e.g. "+1234567890")
- messageBody: the text message content

The SMS is sent directly from the device. The user will be asked to grant SMS permission if not already granted.
