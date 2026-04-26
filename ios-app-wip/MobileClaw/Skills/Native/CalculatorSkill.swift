import Foundation

// 1:1 functional port of android-app/assets/skills/calculator. NSExpression
// handles standard arithmetic with parens and the usual operators.

public final class CalculatorSkill: Skill, @unchecked Sendable {
    public var name: String { "calculator" }
    public var description: String { "Evaluate an arithmetic expression like \"3 * (4 + 5)\"." }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        let expr = args["expression"] ?? args["expr"] ?? ""
        guard !expr.isEmpty else {
            return ToolExecutionResult(success: false, error: "missing 'expression' argument")
        }
        let sanitized = expr.replacingOccurrences(of: "×", with: "*")
                            .replacingOccurrences(of: "÷", with: "/")
        let nsExpr = NSExpression(format: sanitized)
        guard let value = nsExpr.expressionValue(with: nil, context: nil) else {
            return ToolExecutionResult(success: false, error: "could not evaluate: \(expr)")
        }
        return ToolExecutionResult(success: true, output: "\(value)")
    }
}
