import Foundation
import PicardFoundation

public struct FilenameFieldMapping: Codable, Sendable, Equatable, Identifiable {
    public var token: String
    public var tag: String
    public var enabled: Bool
    public var id: String { token }
    public init(token: String, tag: String, enabled: Bool = true) { self.token = token; self.tag = tag; self.enabled = enabled }
}

public struct PreparedFilenameMappings: Sendable {
    fileprivate let entries: [FilenameFieldMapping]
    fileprivate let tokens: Set<String>
}

/// Literal delimiters with explicit capture names; all possible splits are considered, not just a greedy regex guess.
public struct FilenameTagParser: Sendable {
    private enum Part: Sendable { case literal(String), field(String) }
    private let parts: [Part]
    private let tokenSet: Set<String>
    public let tokens: [String]
    public let componentCount: Int
    public init(pattern: String) throws {
        guard !pattern.isEmpty, pattern.count <= 1024 else { throw WorkflowFailure.invalid("Use a filename pattern of 1–1024 characters.") }
        var remaining = pattern[...], parts: [Part] = [], tokens: [String] = []
        while let opening = remaining.firstIndex(of: "{") {
            let literal = String(remaining[..<opening]); if !literal.isEmpty { parts.append(.literal(literal)) }
            guard let closing = remaining[opening...].firstIndex(of: "}") else { throw WorkflowFailure.invalid("A capture is missing its closing }.") }
            let token = String(remaining[remaining.index(after: opening)..<closing])
            guard token.range(of: "^[a-z][a-z0-9_]{0,39}$", options: .regularExpression) != nil,
                  !tokens.contains(token), tokens.count < 12 else { throw WorkflowFailure.invalid("Use up to 12 unique lowercase capture names, such as {artist} and {title}.") }
            if case .field = parts.last { throw WorkflowFailure.invalid("Adjacent captures are ambiguous. Add a literal separator.") }
            tokens.append(token); parts.append(.field(token)); remaining = remaining[remaining.index(after: closing)...]
        }
        if !remaining.isEmpty { parts.append(.literal(String(remaining))) }
        guard !tokens.isEmpty, !pattern.contains(".."), !pattern.hasPrefix("/"), !pattern.contains("\\") else {
            throw WorkflowFailure.invalid("Use relative path components and at least one named capture; / separates folders.")
        }
        self.parts = parts; self.tokens = tokens; tokenSet = Set(tokens); componentCount = pattern.split(separator: "/", omittingEmptySubsequences: false).count
    }
    public func sample(for url: URL) -> String {
        url.deletingPathExtension().pathComponents.suffix(componentCount).joined(separator: "/")
    }
    public enum Result: Sendable, Equatable { case matched([String: String]), unmatched, ambiguous }
    public func parse(_ input: String) -> Result {
        guard input.count <= 4096 else { return .ambiguous }
        var results: [[String: String]] = [], attempts = 0
        func walk(_ part: Int, _ position: String.Index, _ values: [String: String]) {
            guard results.count < 2, attempts < 10_000 else { return }; attempts += 1
            if part == parts.count { if position == input.endIndex { results.append(values) }; return }
            switch parts[part] {
            case let .literal(text):
                if input[position...].hasPrefix(text) { walk(part + 1, input.index(position, offsetBy: text.count), values) }
            case let .field(token):
                func capture(_ end: String.Index) {
                    let text = String(input[position..<end]).trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty, !text.contains("/") else { return }
                    var next = values; next[token] = text; walk(part + 1, end, next)
                }
                if part + 1 == parts.count { capture(input.endIndex); return }
                guard case let .literal(separator) = parts[part + 1] else { return }
                var start = position
                while start < input.endIndex, let range = input.range(of: separator, range: start..<input.endIndex), results.count < 2, attempts < 10_000 {
                    capture(range.lowerBound); start = input.index(after: range.lowerBound)
                }
            }
        }
        walk(0, input.startIndex, [:])
        if attempts >= 10_000 || results.count > 1 { return .ambiguous }
        return results.first.map(Result.matched) ?? .unmatched
    }
    public func metadata(for url: URL, original: Metadata, mappings: [FilenameFieldMapping]) throws -> Metadata {
        try metadata(for: url, original: original, mappings: prepareMappings(mappings))
    }
    public func prepareMappings(_ mappings: [FilenameFieldMapping]) throws -> PreparedFilenameMappings {
        let enabled = mappings.filter(\.enabled)
        guard !enabled.isEmpty, Set(enabled.map(\.token)).count == enabled.count,
              Set(enabled.map { $0.tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }).count == enabled.count,
              enabled.allSatisfy({ tokenSet.contains($0.token) && !$0.tag.trimmingCharacters(in: .whitespaces).isEmpty && !$0.tag.trimmingCharacters(in: .whitespaces).hasPrefix("~") && !$0.tag.contains(where: { $0.isNewline || $0 == "\0" }) }) else {
            throw WorkflowFailure.invalid("Map each enabled capture to a distinct, non-empty tag.")
        }
        return PreparedFilenameMappings(entries: enabled.map {
            FilenameFieldMapping(token: $0.token, tag: $0.tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }, tokens: tokenSet)
    }
    public func metadata(for url: URL, original: Metadata, mappings: PreparedFilenameMappings) throws -> Metadata {
        guard mappings.tokens == tokenSet else { throw WorkflowFailure.invalid("Prepare the mappings for this filename pattern.") }
        let fields: [String: String]
        switch parse(sample(for: url)) {
        case let .matched(values): fields = values
        case .unmatched: throw WorkflowFailure.invalid("Filename does not match the pattern.")
        case .ambiguous: throw WorkflowFailure.invalid("More than one filename split is possible. Refine the pattern; no tags were guessed.")
        }
        var result = original
        for mapping in mappings.entries {
            guard var value = fields[mapping.token] else { continue }
            if ["tracknumber", "discnumber", "totaltracks", "totaldiscs"].contains(mapping.tag) {
                guard value.allSatisfy(\.isNumber), let number = Int(value), (1...9999).contains(number) else { throw WorkflowFailure.invalid("\(mapping.token) must be a positive track/disc number.") }
                value = String(number)
            }
            result.setValue(value, for: mapping.tag)
        }
        return result
    }
}
