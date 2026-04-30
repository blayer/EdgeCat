import Foundation

// 1:1 port of android-app/.../orchestration/ThinkingPolicy.kt

public enum ThinkingMode: Int, Sendable {
    /// Balanced default: thinking on planner-first and repeat-replan; off everywhere else.
    case auto = 0
    /// Everything cold. Fastest, lowest-quality planning on ambiguous requests.
    case off = 1
    /// Thinking on for every reasoning-oriented site (planner, replan, save-as-skill).
    case aggressive = 2

    public static func from(_ i: Int) -> ThinkingMode {
        ThinkingMode(rawValue: i) ?? .auto
    }
}

/// Resolves whether thinking mode should be on for each call site.
/// Call-site policy (cross-model research synthesis):
///   planner-first : AUTO/AGGRESSIVE on (unless trivial one-shot)
///   replan        : AUTO on iteration ≥ 2 only; AGGRESSIVE always on
///   evaluator     : always OFF — small models rationalize/flip on CoT
///   format        : always OFF — #1 source of format drift
///   llm-step      : always OFF — pure synthesis from prior context
///   save-as-skill : only AGGRESSIVE
public struct ThinkingPolicy: Sendable {
    public let mode: ThinkingMode
    public init(mode: ThinkingMode) { self.mode = mode }

    public func planner(userMessage: String, iteration: Int) -> Bool {
        switch mode {
        case .off: return false
        case .auto: return iteration == 0 && !Self.isSimpleRequest(userMessage)
        case .aggressive: return true
        }
    }

    public func replan(replanAttempt: Int) -> Bool {
        switch mode {
        case .off: return false
        case .auto: return replanAttempt >= 2
        case .aggressive: return true
        }
    }

    public func evaluator() -> Bool { false }

    public func format(complexOutput: Bool = false) -> Bool {
        switch mode {
        case .off: return false
        case .auto: return complexOutput
        case .aggressive: return true
        }
    }

    public func llmStep() -> Bool { false }
    public func saveAsSkill() -> Bool { mode == .aggressive }

    private static func isSimpleRequest(_ msg: String) -> Bool {
        let trimmed = msg.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = trimmed.split(whereSeparator: \.isWhitespace).count
        if wordCount <= 4 { return true }
        return simplePrefix.firstMatch(in: trimmed,
                                       range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
    }

    private static let simplePrefix: NSRegularExpression = {
        let pattern = #"^(what time|what['’]?s? the time|set (a )?timer|set (a )?reminder|call |text |open |launch |show me |turn (on|off) )"#
        do {
            return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            fatalError("Failed to compile ThinkingPolicy simplePrefix regex: \(error)")
        }
    }()
}
