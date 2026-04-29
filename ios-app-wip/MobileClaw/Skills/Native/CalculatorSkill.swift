import Foundation

// 1:1 functional port of android-app/assets/skills/calculator. NSExpression
// handles standard arithmetic with parens and the usual operators.

public final class CalculatorSkill: Skill, @unchecked Sendable {
    public var name: String { "calculator" }
    public var description: String {
        "Evaluate a NUMERIC arithmetic expression like \"3 * (4 + 5)\". " +
        "Supports +, -, *, /, %, parentheses, and standard math functions. " +
        "DO NOT use this to summarize, synthesize, draft, or rewrite text — " +
        "this skill is ONLY for arithmetic. For free-form composition, use " +
        "an LLM-only step (description-only with no skillName) and the " +
        "executor will synthesize the answer from prior step outputs. " +
        "DO NOT use this for date or time arithmetic — there's no `date()` function. " +
        "For dates, use the DATE CONTEXT block at the top of the prompt (TODAY, TOMORROW, ONE_WEEK_FROM_NOW, TWO_WEEKS_FROM_NOW) — never compute via calculator."
    }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        let raw = args["expression"] ?? args["expr"] ?? ""
        guard !raw.isEmpty else {
            return ToolExecutionResult(success: false, error: "missing 'expression' argument")
        }
        // Substitute unicode operators BEFORE cleanExpression — × and ÷
        // aren't in the arithmetic charset, so cleanExpression would
        // split "6 × 7" into ["6", "7"] and pick the longest, leaving
        // just "6". Translating up-front preserves the operator.
        let normalized = raw.replacingOccurrences(of: "×", with: "*")
                            .replacingOccurrences(of: "÷", with: "/")
        // Recover an arithmetic expression even if the planner chained
        // a previous step's full output (often JSON like
        // `{"summary":{"total":42},...}`) into the `expression` arg.
        // Extract the first run of `[0-9.+-*/() ]` characters that
        // contains at least one digit and try to evaluate that. If the
        // raw input is already pure-arithmetic, this is a no-op.
        let expr = Self.cleanExpression(normalized)
        guard !expr.isEmpty else {
            return ToolExecutionResult(success: false,
                                        error: "could not extract numeric expression from: \(raw.prefix(60))")
        }
        let sanitized = expr
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/() \t")
        if sanitized.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return ToolExecutionResult(success: false, error: "could not evaluate: \(expr)")
        }
        // Date-shape (YYYY-MM-DD) or two adjacent number literals
        // (e.g. "2026 04") would parse as malformed NSExpression input
        // and raise an uncatchable Obj-C exception that hangs the
        // orchestration step. Reject before NSExpression sees it.
        if Self.looksLikeDateOrInvalidArithmetic(sanitized) {
            return ToolExecutionResult(
                success: false,
                error: "not a calculator expression: \(expr.prefix(60)). " +
                       "Use search-photos with from/to args for date ranges, " +
                       "or use the DATE CONTEXT block for date arithmetic.")
        }
        let nsExpr = NSExpression(format: sanitized)
        guard let value = nsExpr.expressionValue(with: nil, context: nil) else {
            return ToolExecutionResult(success: false, error: "could not evaluate: \(expr)")
        }
        return ToolExecutionResult(success: true, output: "\(value)")
    }

    /// Pull a clean arithmetic expression out of the input. Lets the
    /// calculator survive a planner that piped a small JSON output into
    /// the `expression` arg — but only when the input is recognizably a
    /// math expression. For free-form prose the function returns "" so
    /// the caller fails fast instead of silently evaluating "-8" because
    /// some random number was buried in a paragraph.
    ///
    /// Heuristic: accept input where ≥70% of non-space characters are
    /// arithmetic. Otherwise reject (return "").
    static func cleanExpression(_ s: String) -> String {
        let arithChars = CharacterSet(charactersIn: "0123456789.+-*/() \t")
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        // Pure-arithmetic input passes through untouched.
        if trimmed.unicodeScalars.allSatisfy({ arithChars.contains($0) }) {
            return trimmed
        }
        // Count how arithmetic-shaped the input actually is. Rejecting
        // mostly-prose inputs prevents the planner from accidentally
        // calling calculator on synthesis tasks ("draft an itinerary…")
        // and getting back a meaningless number scraped from prose.
        let nonSpace = trimmed.unicodeScalars.filter { $0 != " " && $0 != "\t" }
        guard !nonSpace.isEmpty else { return "" }
        let arithCount = nonSpace.filter { arithChars.contains($0) }.count
        let ratio = Double(arithCount) / Double(nonSpace.count)
        guard ratio >= 0.7 else { return "" }
        // Mostly arithmetic but contains a few stray non-arith chars
        // (commas, currency signs from e.g. "$3.50 + $1.25"). Strip
        // them and return the cleaned expression.
        var cleaned = ""
        for scalar in trimmed.unicodeScalars where arithChars.contains(scalar) {
            cleaned.unicodeScalars.append(scalar)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pattern guard for inputs that pass the charset check but would
    /// crash NSExpression(format:). Three classes:
    /// 1. Date shapes: `YYYY-MM-DD` (subtraction-of-three-numbers).
    /// 2. Two adjacent multi-digit numbers separated by space — NSExpression
    ///    can't decide whether `2026 04` is one number or two.
    /// 3. Trailing binary operators (`3 +`) or two adjacent operators
    ///    (`3 + +`) — malformed expressions.
    static func looksLikeDateOrInvalidArithmetic(_ s: String) -> Bool {
        // Class 1 — `\b\d{4}-\d{2}-\d{2}\b`
        if s.range(of: #"\b\d{4}-\d{1,2}-\d{1,2}\b"#,
                   options: .regularExpression) != nil { return true }
        // Class 2 — two multi-digit numbers separated by spaces
        if s.range(of: #"\b\d{2,}\s+\d{2,}\b"#,
                   options: .regularExpression) != nil { return true }
        // Class 3 — trailing or doubled operators (after collapsing
        // whitespace). `--` is allowed because NSExpression treats it
        // as unary-minus on a negative literal.
        let collapsed = s.replacingOccurrences(of: " ", with: "")
                         .replacingOccurrences(of: "\t", with: "")
        if collapsed.last.map({ "+-*/".contains($0) }) == true { return true }
        if collapsed.range(of: #"[+*/]{2,}|[+/]{2,}|\*\*"#,
                           options: .regularExpression) != nil { return true }
        return false
    }
}
