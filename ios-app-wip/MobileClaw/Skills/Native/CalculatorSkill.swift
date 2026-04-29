import Foundation

// 1:1 functional port of android-app/assets/skills/calculator. NSExpression
// handles standard arithmetic with parens and the usual operators.

public final class CalculatorSkill: Skill, @unchecked Sendable {
    public var name: String { "calculator" }
    public var description: String {
        "Evaluate a NUMERIC arithmetic expression like \"3 * (4 + 5)\". " +
        "Supports +, -, *, /, %, parentheses, and standard math functions. " +
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
        let nsExpr = NSExpression(format: sanitized)
        guard let value = nsExpr.expressionValue(with: nil, context: nil) else {
            return ToolExecutionResult(success: false, error: "could not evaluate: \(expr)")
        }
        return ToolExecutionResult(success: true, output: "\(value)")
    }

    /// Pull the longest substring of arithmetic-friendly characters out
    /// of the input. Lets the calculator survive a planner that piped a
    /// JSON output into the `expression` arg — we extract the first
    /// numeric expression we can find rather than rejecting the call.
    static func cleanExpression(_ s: String) -> String {
        // If `s` is already mostly arithmetic, take it as-is.
        let arithChars = CharacterSet(charactersIn: "0123456789.+-*/() \t")
        let mostlyArithmetic = s.unicodeScalars.allSatisfy { arithChars.contains($0) }
        if mostlyArithmetic { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Otherwise scan for runs of arithmetic chars and pick the
        // longest run that contains at least one digit.
        var best = ""
        var current = ""
        for scalar in s.unicodeScalars {
            if arithChars.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                if current.contains(where: { $0.isNumber }) && current.count > best.count {
                    best = current
                }
                current = ""
            }
        }
        if current.contains(where: { $0.isNumber }) && current.count > best.count {
            best = current
        }
        return best.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
