import Foundation

// 1:1 port of android-app/.../orchestration/Planner.kt::classifyIntent — uses
// regex heuristics to decide whether a user message is an actionable task or
// casual conversation, BEFORE we spend an LLM inference on plan generation.
// Routes greetings / small talk through the plain-LLM chat path even when
// agentic mode is on.

public enum Intent: String, Sendable {
    case task
    case chat
}

public enum IntentClassifier {
    /// Patterns that always route to chat when matched at the start of a
    /// trimmed, lower-cased message. Order matters only for readability.
    private static let chatPatterns: [NSRegularExpression] = [
        #"^(hi|hey|hello|howdy|yo|sup)\b"#,
        #"^(good\s+(morning|afternoon|evening|night))\b"#,
        #"^how\s+are\s+you"#,
        #"^what'?s\s+up"#,
        #"^thank(s| you)"#,
        #"^(bye|goodbye|see you|later)\b"#,
        #"^(ok|okay|sure|great|nice|cool|awesome)$"#,
        #"^who\s+are\s+you"#,
        #"^what\s+is\s+your\s+name"#,
        #"^tell\s+me\s+(about\s+yourself|a\s+joke)"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Substring tokens that indicate the user is asking the device to do
    /// something. Checked before follow-up markers so "then set an alarm"
    /// still routes to task.
    private static let taskKeywords: [String] = [
        "search", "find", "look up", "set", "create", "send", "call", "open",
        "calculate", "remind", "alarm", "timer", "weather", "calendar", "email",
        "sms", "message", "photo", "download", "clipboard", "copy", "volume",
        "flashlight", "location", "contacts", "apps", "launch", "share",
        "fetch", "browse", "navigate", "check", "device", "battery",
        "bluetooth", "wifi", "settings", "do not disturb",
        "summarize", "show", "get", "tell me", "what is", "what are",
        "how much", "how many",
    ]

    /// Pronouns/adverbs that lean on a prior turn and carry no new task of
    /// their own. Only routes to chat when a prior assistant reply exists,
    /// so a cold-start ambiguous question still gets planned.
    private static let followUpPatterns: [NSRegularExpression] = [
        #"^(so|then|and|but|ok|okay|well)[,.!?\s]"#,
        #"\b(what|how)\s+(about|else|next|then)\b"#,
        #"^why(\s+not)?\b"#,
        #"^then\s+what\b"#,
        #"^(what|which)\s+(should|do|would|can)\s+(we|i|you)\b.*\b(then|next|now|instead)\b"#,
        #"\b(that|those|these|it|they|them|which)\s+(one|ones)?\s*[?.!]?$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func classify(_ userMessage: String,
                                 hasPriorAssistantTurn: Bool = false) -> Intent {
        let lower = userMessage
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let nsRange = NSRange(lower.startIndex..<lower.endIndex, in: lower)

        // 1. Chat patterns win unconditionally.
        for re in chatPatterns where re.firstMatch(in: lower, options: [], range: nsRange) != nil {
            return .chat
        }

        // 2. Task keywords — check before follow-up markers so "then set an
        //    alarm" doesn't get hijacked by the "then" follow-up pattern.
        for keyword in taskKeywords where lower.contains(keyword) {
            return .task
        }

        // 3. Follow-up markers — only when there's an assistant turn to
        //    follow up on. Otherwise treat as a fresh question and plan.
        if hasPriorAssistantTurn {
            for re in followUpPatterns where re.firstMatch(in: lower, options: [], range: nsRange) != nil {
                return .chat
            }
        }

        // 4. Substantive question (long enough to be more than a greeting) → task.
        if lower.contains("?") && lower.count > 20 {
            return .task
        }

        // 5. Very short with no task keywords → chat.
        let wordCount = lower.split(whereSeparator: { $0.isWhitespace }).count
        if wordCount <= 3 {
            return .chat
        }

        // 6. Default to task — better to plan unnecessarily than miss a request.
        return .task
    }
}
