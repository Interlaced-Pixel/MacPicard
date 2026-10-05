import Foundation

/// NSRegularExpression is immutable after construction. The bounded cache is
/// shared by copies of an evaluator and synchronized for concurrent workflows.
final class ScriptRegexCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: NSRegularExpression] = [:]
    private var order: [String] = []
    func expression(_ pattern: String) throws -> NSRegularExpression {
        lock.lock(); defer { lock.unlock() }
        if let cached = entries[pattern] { return cached }
        let expression = try NSRegularExpression(pattern: pattern)
        entries[pattern] = expression; order.append(pattern)
        if order.count > 32 { entries.removeValue(forKey: order.removeFirst()) }
        return expression
    }
}
