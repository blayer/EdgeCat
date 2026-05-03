import Foundation

// Mirrors the step-arg cleanup logic in
// android-app/.../orchestration/ExecutionOrchestrator.kt::executeStep
// (lines 195-380). Small models routinely emit args like "tomorrow at 9am"
// or "Output from step_1" instead of the canonical iso-datetime / actual
// upstream output. The rescue layer normalizes those before the tool is
// called so the skill itself doesn't have to handle them.

public enum StepArgRescue {

    /// Normalize a single arg dictionary, given prior step outputs to use
    /// for placeholder substitution. Returns a new dictionary; does not
    /// mutate the input.
    ///
    /// `goal` is the planner's restated goal — used as a fallback source
    /// when title-shaped args are empty/placeholder after substitution.
    /// Pass empty string when no goal is available; the title rescue is
    /// a no-op then.
    public static func rescue(args: [String: String],
                              dependencies: [String: String],
                              now: Date = Date(),
                              goal: String = "",
                              userMessage: String = "",
                              conversationContext: String = "",
                              skillName: String = "") -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in args {
            var v = value
            v = substitutePlaceholders(v, dependencies: dependencies)
            v = extractUrlIfNeeded(v, key: key)
            v = extractTitleHintIfNeeded(v, key: key, goal: goal)
            // Conversation-context binding: when a write-side skill
            // (set-reminder, add-calendar-event) emits a title that
            // doesn't reference any entity from prior turns, replace
            // it with one. Catches yoga turn 3 ("Remind me one hour
            // before it starts") where the planner emits title=
            // "Reminder for one hour before event" — generic, no
            // pronoun bind. We detect "no entity overlap with the
            // conversation" and pull one from prior assistant turns.
            v = bindTitleToConversationIfNeeded(
                v, key: key, skillName: skillName,
                userMessage: userMessage,
                conversationContext: conversationContext)
            // NOTE: photo_id / asset_id values are NOT extracted here —
            // BarcodeSkill and RecognizeTextSkill already iterate the
            // full search-photos JSON envelope via
            // `RecognizeTextSkill.extractAllImageIds` to walk every
            // candidate. Picking just the first id here would defeat
            // that multi-photo retry on tasks like qr-scan where the
            // matching asset isn't always #1 in the recents list.
            v = normalizeDateTime(v, now: now)
            v = normalizePhoneNumber(v, key: key)
            out[key] = v
        }
        return out
    }

    /// When the arg key is title-shaped (`title`, `name`, `subject`,
    /// `label`) and the value after substitution is empty, a placeholder,
    /// or the raw JSON envelope from a prior step, fall back to a quoted
    /// string in the goal text. The planner often gets the title right
    /// in the user-message echo (e.g. "add a calendar event for 'Call mom'
    /// tomorrow at 6pm") but emits an empty `title` arg or leaves
    /// `Output from s1` in there, which downstream calendar/reminder
    /// skills reject as `missing 'title' argument`.
    static func extractTitleHintIfNeeded(_ value: String, key: String, goal: String) -> String {
        let titleKeys: Set<String> = ["title", "name", "subject", "label"]
        guard titleKeys.contains(key) else { return value }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Real-looking value? Pass through.
        if !trimmed.isEmpty
            && !trimmed.lowercased().hasPrefix("output from")
            && !trimmed.lowercased().hasPrefix("<output of")
            && !trimmed.hasPrefix("{")  // raw JSON envelope from upstream
            && !trimmed.hasPrefix("[") {
            return value
        }
        // Pull a quoted phrase out of the goal — single quotes preferred
        // since the user/eval prompts use them around proper-noun titles
        // ('Call mom', 'iOS Eval Test'). Falls back to double quotes.
        guard !goal.isEmpty else { return value }
        let patterns = [#"'([^']{1,80})'"#, #""([^"]{1,80})""#]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(goal.startIndex..<goal.endIndex, in: goal)
            if let m = re.firstMatch(in: goal, options: [], range: range),
               m.numberOfRanges >= 2,
               let r = Range(m.range(at: 1), in: goal) {
                let candidate = String(goal[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty { return candidate }
            }
        }
        return value
    }

    /// Replace a planner-emitted title that doesn't bind to any
    /// conversation entity with a noun phrase pulled from a prior
    /// assistant turn. Only fires for write-side skills (set-reminder,
    /// add-calendar-event) and only when the existing title looks
    /// generic — i.e. doesn't share any non-stopword token with the
    /// recent conversation OR matches a known boilerplate shape
    /// ("Reminder for X", "Event for X", "an unspecified item").
    /// No-op when conversationContext is empty or no entity is found.
    static func bindTitleToConversationIfNeeded(
        _ value: String,
        key: String,
        skillName: String,
        userMessage: String,
        conversationContext: String,
    ) -> String {
        let titleKeys: Set<String> = ["title", "name", "subject", "label"]
        guard titleKeys.contains(key) else { return value }
        let writeSkills: Set<String> = [
            "set-reminder", "reminders",
            "add-calendar-event",
            "share-content",
        ]
        guard writeSkills.contains(skillName.lowercased()) else { return value }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return value }
        // Boilerplate shapes the planner emits when it can't bind a
        // pronoun: "Reminder", "Event for next Friday", "Reminder for
        // one hour before event", "an unspecified item to the user's
        // calendar." All flag as generic.
        let lowered = trimmed.lowercased()
        let boilerplate = [
            "^reminder$",
            "^event$",
            "^reminder for ",
            "^event for ",
            "^an unspecified ",
            " unspecified item",
        ]
        let looksBoilerplate = boilerplate.contains { p in
            lowered.range(of: p, options: .regularExpression) != nil
        }
        // Also flag generic if the title doesn't share any 4+-char
        // non-stop token with the user's most recent message OR
        // the conversation context. Cheap "does this title relate
        // to what we've been talking about" check.
        let convo = (userMessage + " " + conversationContext).lowercased()
        let titleTokens = lowered
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 }
        let stop: Set<String> = [
            "reminder", "event", "calendar", "thing", "item", "task",
            "schedule", "before", "after", "minute", "hour", "starts",
            "later", "today", "tomorrow",
        ]
        let nonStopTitleTokens = titleTokens.filter { !stop.contains($0) }
        let bindsToConvo = nonStopTitleTokens.contains { convo.contains($0) }
        guard looksBoilerplate || (!nonStopTitleTokens.isEmpty == false && !bindsToConvo)
                || nonStopTitleTokens.isEmpty else {
            return value
        }
        // Try to extract an entity from prior assistant turns.
        guard let entity = extractEntityFromConversation(conversationContext)
                        ?? extractEntityFromConversation(userMessage)
        else { return value }
        return entity
    }

    /// Walk assistant blocks newest-to-oldest looking for a named
    /// entity (Title: X / quoted phrase / TitleCase noun). Mirrors the
    /// OrchestrationController injector heuristic but local here so
    /// the rescue layer can use it without a circular import.
    static func extractEntityFromConversation(_ context: String) -> String? {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let blocks = trimmed.components(separatedBy: "Assistant:")
            .dropFirst()
            .map { $0.components(separatedBy: "User:").first ?? $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Walk OLDEST → newest so the first-established topic of the
        // conversation wins (e.g. yoga case: Turn 1 says "Yoga for
        // Harmony & Peace", Turn 2's success envelope mentions
        // "Harmony & Peace Join" which is a fragment — the persistent
        // topic is "Yoga"). Reversing newer-first incidentally favored
        // Turn 2 fragments and broke yoga-binding for the Turn 3
        // reminder.
        let userBlocks = trimmed.components(separatedBy: "User:")
            .dropFirst()
            .map { $0.components(separatedBy: "Assistant:").first ?? $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let stop: Set<String> = [
            "the", "this", "that", "you", "we", "today",
            "tomorrow", "yesterday", "user", "assistant", "no",
            "yes", "ok", "sure", "to", "for", "and", "or",
            "i", "in", "on", "at", "by", "of", "an", "a",
            "reminder", "event",
        ]
        for block in blocks {
            // Title: X — formatter format.
            if let r = try? NSRegularExpression(
                pattern: #"Title:\s*([^,\n]{2,60})"#,
                options: .caseInsensitive),
               let m = r.firstMatch(
                in: block,
                range: NSRange(block.startIndex..<block.endIndex, in: block)),
               let inner = Range(m.range(at: 1), in: block) {
                return String(block[inner]).trimmingCharacters(in: .whitespaces)
            }
            // Quoted phrase. Skip JSON keys ("title":"value") — those
            // match the regex but are field names, not entities. The
            // prior assistant's add-calendar-event success envelope
            // emits {"title":"free yoga class …"} and we want the
            // value, not the key.
            for pattern in [#"'([^']{2,80})'"#, #""([^"]{2,80})""#] {
                guard let r = try? NSRegularExpression(pattern: pattern)
                else { continue }
                let nsr = NSRange(block.startIndex..<block.endIndex, in: block)
                for m in r.matches(in: block, options: [], range: nsr) {
                    guard let outer = Range(m.range, in: block),
                          let inner = Range(m.range(at: 1), in: block)
                    else { continue }
                    // Look at the character right after the closing
                    // quote — if it's `:`, this match is a JSON key.
                    let afterIdx = outer.upperBound
                    if afterIdx < block.endIndex, block[afterIdx] == ":" {
                        continue
                    }
                    let candidate = String(block[inner])
                        .trimmingCharacters(in: .whitespaces)
                    // Filter single-word generic keys that crept in.
                    let lower = candidate.lowercased()
                    let stopKeys: Set<String> = [
                        "title", "name", "subject", "label",
                        "status", "result", "value", "id",
                        "succeeded", "failed", "ok", "error",
                        "calendar", "reminder", "default",
                    ]
                    if stopKeys.contains(lower) { continue }
                    // Filter ISO timestamps, dates, pure numbers — these
                    // are JSON values that aren't user-meaningful titles.
                    if candidate.range(
                        of: #"^\d{4}-\d{2}-\d{2}"#,
                        options: .regularExpression) != nil { continue }
                    if candidate.range(
                        of: #"^\d+(\.\d+)?$"#,
                        options: .regularExpression) != nil { continue }
                    if candidate.range(
                        of: #"^https?://"#,
                        options: .regularExpression) != nil { continue }
                    if !candidate.isEmpty { return candidate }
                }
            }
            // Multi-word TitleCase (e.g. "Yoga for Harmony & Peace").
            if let multi = try? NSRegularExpression(
                pattern: #"\b([A-Z][a-z]+(?:\s+(?:&\s+)?[A-Z][a-z]+){1,4})\b"#) {
                let nsr = NSRange(block.startIndex..<block.endIndex, in: block)
                for m in multi.matches(in: block, range: nsr) {
                    guard let inner = Range(m.range(at: 1), in: block)
                    else { continue }
                    let candidate = String(block[inner])
                    if !stop.contains(candidate.lowercased()),
                       candidate.count >= 4 {
                        return candidate
                    }
                }
            }
            // Single-word TitleCase noun.
            if let single = try? NSRegularExpression(
                pattern: #"\b([A-Z][a-z]{2,})\b"#) {
                let nsr = NSRange(block.startIndex..<block.endIndex, in: block)
                for m in single.matches(in: block, range: nsr) {
                    guard let inner = Range(m.range(at: 1), in: block)
                    else { continue }
                    let candidate = String(block[inner])
                    if !stop.contains(candidate.lowercased()) {
                        return candidate
                    }
                }
            }
        }
        // Fallback: scan user blocks (oldest-relevant for entity since
        // the user usually establishes the entity in the first turn).
        // Strips common request-prefix verbs ("Remind me to", "Add an
        // event for", "Set a reminder to") and returns the rest if
        // it looks like a noun phrase (≥ 2 chars, ≥ 1 letter).
        let prefixes = [
            "remind me to ", "remind me about ", "remind me of ",
            "add ", "set a reminder to ", "set a reminder for ",
            "set a reminder about ", "schedule ", "create a reminder to ",
            "create a reminder for ", "book ",
        ]
        for block in userBlocks {
            let lower = block.lowercased()
            for prefix in prefixes where lower.hasPrefix(prefix) {
                var rest = String(block.dropFirst(prefix.count))
                // Trim trailing temporal/location clauses ("at Whole
                // Foods on Stevens Creek", "tomorrow at 5pm").
                let trailingCutters = [
                    " at ", " on ", " for ", " in ",
                    " tomorrow", " today", " tonight",
                ]
                for cutter in trailingCutters {
                    if let r = rest.range(of: cutter) {
                        rest = String(rest[..<r.lowerBound])
                        break
                    }
                }
                rest = rest.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: .punctuationCharacters)
                if rest.count >= 2,
                   rest.contains(where: \.isLetter),
                   !stop.contains(rest.lowercased()) {
                    return rest
                }
            }
        }
        return nil
    }

    /// When the arg key is URL-shaped (`url`, `link`, `href`) and the
    /// substituted value isn't yet a clean URL, scrape the first
    /// `https?://…` token out of it. Lets `fetch-web-content` chain
    /// directly off `search-web`'s output — search-web returns the
    /// full results JSON, but fetch-web-content needs just one URL.
    static func extractUrlIfNeeded(_ value: String, key: String) -> String {
        let urlishKeys: Set<String> = ["url", "link", "href"]
        guard urlishKeys.contains(key) else { return value }
        // Un-escape JSON slashes BEFORE the URL scan. Swift's
        // `JSONSerialization.data(withJSONObject:)` defaults to
        // emitting `\/` for forward slashes, so search-web's output
        // contains `https:\/\/www.accuweather.com\/...`. Without this
        // step the regex below would capture only `https:` and the
        // chained fetch-web-content step fails with `invalid 'url'`.
        let unescaped = value.replacingOccurrences(of: #"\/"#, with: "/")
        let trimmed = unescaped.trimmingCharacters(in: .whitespacesAndNewlines)
        // Already a clean URL? Pass through.
        if let u = URL(string: trimmed), u.scheme == "http" || u.scheme == "https" {
            return trimmed
        }
        // Scrape the first http(s) URL from the value. Stops at
        // whitespace, quotes, brackets, AND backslash — search-web's
        // output is JSON-serialized so newlines come through as the
        // two-char escape `\n`, and including those would produce
        // "https://example.com\n" which URL(string:) rejects.
        let pattern = #"https?://[^\s"'<>\\]+"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let m = re.firstMatch(in: trimmed, options: [], range: range),
              let r = Range(m.range, in: trimmed) else { return value }
        // Strip trailing punctuation commonly attached to URLs in prose
        // (sentence-ending . , ; : ! ?, closing brackets) — these aren't
        // part of the URL but the regex would happily eat them.
        var matched = String(trimmed[r])
        let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}"]
        while let last = matched.last, trailing.contains(last) {
            matched.removeLast()
        }
        // Validate — fall back to original if the scraped URL doesn't parse.
        guard let u = URL(string: matched), u.scheme == "http" || u.scheme == "https" else {
            return value
        }
        return u.absoluteString
    }

    /// Replace placeholder values that reference a prior step output. The
    /// LLM often writes `"Output from s1"` or `"<output of step_1>"` — we
    /// look for any prior step ID inside the value and substitute the
    /// truncated output.
    static func substitutePlaceholders(_ value: String, dependencies: [String: String]) -> String {
        guard !dependencies.isEmpty else { return value }
        var v = value
        for (stepId, output) in dependencies where output.isEmpty == false {
            let normalizedId = stepId.replacingOccurrences(of: "_", with: "-")
            // Match "<stepId>", "Output from <stepId>", "<output of <stepId>>".
            // Cheap substring check first to avoid regex compilation.
            if v.lowercased().contains(stepId.lowercased())
                || v.lowercased().contains(normalizedId.lowercased())
                || v.lowercased().hasPrefix("output from")
                || v.lowercased().hasPrefix("<output of") {
                // Bumped 500 → 1500. search-photos' fallback envelope
                // (note text + 3 items × ~80 chars) totals ~400-600
                // chars; at the old 500 cap the trailing photo ids
                // got truncated, breaking scan-barcode's multi-photo
                // retry. fetch-web-content / search-web outputs are
                // already truncated to 4000 chars so 1500 here is well
                // under the upstream skill cap.
                v = String(output.prefix(1500))
                break
            }
        }
        return v
    }

    /// Normalize relative date-time strings into yyyy-MM-ddTHH:mm format.
    /// Examples handled: "tomorrow at 9am", "today at 11pm", "2026-04-27 14:30".
    /// Anything already in yyyy-MM-ddTHH:mm is passed through unchanged.
    static func normalizeDateTime(_ value: String, now: Date) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCanonicalDateTime(trimmed) { return trimmed }

        let lower = trimmed.lowercased()
        let cal = Calendar(identifier: .gregorian)
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.locale = Locale(identifier: "en_US_POSIX")
        dateFmt.timeZone = TimeZone.current

        var baseDate: Date?
        var remainder: String?
        if lower.contains("tomorrow") {
            baseDate = cal.date(byAdding: .day, value: 1, to: now)
            remainder = lower.replacingOccurrences(of: "tomorrow", with: "")
        } else if lower.contains("today") || lower.contains("tonight") {
            baseDate = now
            remainder = lower
                .replacingOccurrences(of: "today", with: "")
                .replacingOccurrences(of: "tonight", with: "")
        } else if lower.contains("yesterday") {
            baseDate = cal.date(byAdding: .day, value: -1, to: now)
            remainder = lower.replacingOccurrences(of: "yesterday", with: "")
        }

        if let base = baseDate, let rem = remainder, let time = parseTime(rem) {
            let day = dateFmt.string(from: base)
            return "\(day)T\(time)"
        }

        // Try to coerce "yyyy-MM-dd HH:mm" → "yyyy-MM-ddTHH:mm".
        if let space = trimmed.firstIndex(of: " "),
           trimmed.distance(from: trimmed.startIndex, to: space) == 10 {
            return trimmed.replacingCharacters(in: space...space, with: "T")
        }

        return trimmed
    }

    private static func isCanonicalDateTime(_ s: String) -> Bool {
        guard s.count >= 16 else { return false }
        let pattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}"
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    /// Extract HH:mm from "9am", "9:30am", "9 PM", "23:00", etc.
    static func parseTime(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
        // 24-hour HH:mm.
        if let m = trimmed.range(of: #"\b([01]?[0-9]|2[0-3]):([0-5][0-9])\b"#,
                                  options: .regularExpression) {
            let parts = trimmed[m].split(separator: ":")
            if parts.count == 2,
               let h = Int(parts[0]), let mm = Int(parts[1]) {
                return String(format: "%02d:%02d", h, mm)
            }
        }
        // 12-hour h(:mm)? am/pm.
        let pattern = #"\b(1[0-2]|[1-9])(?::([0-5][0-9]))?\s*(am|pm)\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = re.firstMatch(in: trimmed, options: [], range: range) else { return nil }
        guard let hourRange = Range(match.range(at: 1), in: trimmed),
              let suffixRange = Range(match.range(at: 3), in: trimmed),
              var hour = Int(trimmed[hourRange]) else { return nil }
        let minute: Int
        if match.range(at: 2).location != NSNotFound,
           let mr = Range(match.range(at: 2), in: trimmed),
           let m = Int(trimmed[mr]) {
            minute = m
        } else {
            minute = 0
        }
        let suffix = String(trimmed[suffixRange])
        if suffix == "pm", hour < 12 { hour += 12 }
        if suffix == "am", hour == 12 { hour = 0 }
        return String(format: "%02d:%02d", hour, minute)
    }

    /// For args whose key suggests a phone number, strip everything but
    /// digits and a leading `+`. Keeps text args (names, messages) intact.
    static func normalizePhoneNumber(_ value: String, key: String) -> String {
        let phoneishKeys: Set<String> = [
            "phone", "phoneNumber", "phone_number", "to", "number", "recipient",
        ]
        guard phoneishKeys.contains(key) else { return value }
        var digits = ""
        if value.hasPrefix("+") { digits.append("+") }
        for ch in value where ch.isNumber { digits.append(ch) }
        return digits.isEmpty ? value : digits
    }
}
