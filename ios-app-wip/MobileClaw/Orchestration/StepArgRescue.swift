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
    public static func rescue(args: [String: String],
                              dependencies: [String: String],
                              now: Date = Date()) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in args {
            var v = value
            v = substitutePlaceholders(v, dependencies: dependencies)
            v = extractUrlIfNeeded(v, key: key)
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
