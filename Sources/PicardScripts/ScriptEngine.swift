import Foundation
import PicardFoundation

public struct ScriptSourceLocation: Codable, Sendable, Equatable {
    public let offset: Int
    public let line: Int
    public let column: Int

    public init(offset: Int, line: Int, column: Int) {
        self.offset = offset
        self.line = line
        self.column = column
    }
}

public enum ScriptError: Error, LocalizedError, Sendable, Equatable {
    case unexpectedEnd(ScriptSourceLocation)
    case unexpectedCharacter(Character, ScriptSourceLocation)
    case invalidVariable(ScriptSourceLocation)
    case invalidFunction(ScriptSourceLocation)
    case missingFunctionTerminator(String, ScriptSourceLocation)
    case invalidEscape(String, ScriptSourceLocation)
    case unknownFunction(String, ScriptSourceLocation)
    case invalidArgument(function: String, message: String, location: ScriptSourceLocation)
    case invalidRegularExpression(String, ScriptSourceLocation)
    case invalidNumber(String, ScriptSourceLocation)

    public var errorDescription: String? {
        switch self {
        case let .unexpectedEnd(location):
            return "Script ended unexpectedly at \(location.line):\(location.column)."
        case let .unexpectedCharacter(character, location):
            return "Unexpected character '\(character)' at \(location.line):\(location.column)."
        case let .invalidVariable(location):
            return "Invalid variable expression at \(location.line):\(location.column)."
        case let .invalidFunction(location):
            return "Invalid function expression at \(location.line):\(location.column)."
        case let .missingFunctionTerminator(name, location):
            return "Function $\(name) is missing ')' at \(location.line):\(location.column)."
        case let .invalidEscape(value, location):
            return "Invalid escape sequence \\\(value) at \(location.line):\(location.column)."
        case let .unknownFunction(name, location):
            return "Unknown scripting function $\(name) at \(location.line):\(location.column)."
        case let .invalidArgument(function, message, location):
            return "Invalid argument for $\(function) at \(location.line):\(location.column): \(message)"
        case let .invalidRegularExpression(pattern, location):
            return "Invalid regular expression '\(pattern)' at \(location.line):\(location.column)."
        case let .invalidNumber(value, location):
            return "Invalid number '\(value)' at \(location.line):\(location.column)."
        }
    }
}

public indirect enum ScriptNode: Codable, Sendable, Equatable {
    case sequence([ScriptNode])
    case literal(String, ScriptSourceLocation)
    case variable(String, ScriptSourceLocation)
    case function(name: String, arguments: [ScriptNode], ScriptSourceLocation)
}

public struct ScriptProgram: Codable, Sendable, Equatable {
    public let source: String
    public let nodes: [ScriptNode]

    public init(source: String, nodes: [ScriptNode]) {
        self.source = source
        self.nodes = nodes
    }
}

public struct ScriptParser: Sendable {
    public init() {}

    public func parse(_ source: String) throws -> ScriptProgram {
        var parser = Parser(source: source)
        let nodes = try parser.parseDocument()
        return ScriptProgram(source: source, nodes: nodes)
    }

    private struct Parser {
        let source: String
        let characters: [Character]
        var index: Int = 0

        init(source: String) {
            self.source = source
            self.characters = Array(source)
        }

        mutating func parseDocument() throws -> [ScriptNode] {
            let nodes = try parseSequence(stoppingAt: [])
            guard index == characters.count else {
                throw ScriptError.unexpectedCharacter(characters[index], location())
            }
            return nodes
        }

        mutating func parseSequence(stoppingAt terminators: Set<Character>) throws -> [ScriptNode] {
            var nodes: [ScriptNode] = []
            var literal = String()
            var literalLocation: ScriptSourceLocation?

            func appendLiteral(_ value: String, to nodes: inout [ScriptNode], literal: inout String, location: inout ScriptSourceLocation?) {
                if location == nil {
                    location = ScriptSourceLocation(offset: 0, line: 1, column: 1)
                }
                literal.append(value)
            }

            func flushLiteral() {
                guard !literal.isEmpty else { return }
                nodes.append(.literal(literal, literalLocation ?? ScriptSourceLocation(offset: 0, line: 1, column: 1)))
                literal.removeAll(keepingCapacity: true)
                literalLocation = nil
            }

            while index < characters.count {
                let character = characters[index]
                if terminators.contains(character) {
                    break
                }

                switch character {
                case "%":
                    flushLiteral()
                    nodes.append(try parseVariable())
                case "$":
                    flushLiteral()
                    nodes.append(try parseFunction())
                case "\\":
                    if literalLocation == nil { literalLocation = location() }
                    literal.append(try parseEscape())
                case "\"", "'":
                    if literalLocation == nil { literalLocation = location() }
                    literal.append(try parseQuotedLiteral())
                default:
                    if literalLocation == nil { literalLocation = location() }
                    literal.append(character)
                    index += 1
                }
            }

            flushLiteral()
            return nodes
        }

        mutating func parseVariable() throws -> ScriptNode {
            let start = location()
            index += 1
            guard index < characters.count else {
                throw ScriptError.unexpectedEnd(start)
            }
            if characters[index] == "%" {
                index += 1
                return .literal("%", start)
            }

            let begin = index
            while index < characters.count, characters[index] != "%" {
                let character = characters[index]
                guard character.isLetter || character.isNumber || character == "_" || character == "-" || character == "." else {
                    throw ScriptError.invalidVariable(location())
                }
                index += 1
            }
            guard begin < index, index < characters.count else {
                throw ScriptError.invalidVariable(start)
            }
            let name = String(characters[begin..<index])
            index += 1
            return .variable(name, start)
        }

        mutating func parseFunction() throws -> ScriptNode {
            let start = location()
            index += 1
            guard index < characters.count else {
                throw ScriptError.unexpectedEnd(start)
            }
            if characters[index] == "$" {
                index += 1
                return .literal("$", start)
            }

            let begin = index
            while index < characters.count {
                let character = characters[index]
                guard character.isLetter || character.isNumber || character == "_" else { break }
                index += 1
            }
            guard begin < index else {
                throw ScriptError.invalidFunction(start)
            }
            let name = String(characters[begin..<index])
            guard index < characters.count, characters[index] == "(" else {
                throw ScriptError.invalidFunction(start)
            }
            index += 1

            var arguments: [ScriptNode] = []
            if index < characters.count, characters[index] == ")" {
                index += 1
                return .function(name: name, arguments: arguments, start)
            }

            while true {
                let argument = try parseSequence(stoppingAt: [",", ")"])
                arguments.append(.sequence(argument))
                guard index < characters.count else {
                    throw ScriptError.missingFunctionTerminator(name, start)
                }
                if characters[index] == ")" {
                    index += 1
                    break
                }
                guard characters[index] == "," else {
                    throw ScriptError.unexpectedCharacter(characters[index], location())
                }
                index += 1
                if index < characters.count, characters[index] == ")" {
                    arguments.append(.sequence([]))
                    index += 1
                    break
                }
            }

            return .function(name: name, arguments: arguments, start)
        }

        mutating func parseQuotedLiteral() throws -> String {
            let quote = characters[index]
            index += 1
            var result = String()
            while index < characters.count {
                if characters[index] == quote {
                    index += 1
                    return result
                }
                if characters[index] == "\\" {
                    result.append(try parseEscape())
                } else {
                    result.append(characters[index])
                    index += 1
                }
            }
            throw ScriptError.unexpectedEnd(location())
        }

        mutating func parseEscape() throws -> Character {
            let start = location()
            index += 1
            guard index < characters.count else {
                throw ScriptError.unexpectedEnd(start)
            }
            let escaped = characters[index]
            index += 1
            switch escaped {
            case "n": return "\n"
            case "r": return "\r"
            case "t": return "\t"
            case "\\", "%", "$", "\"", "'", ",", "(", ")": return escaped
            case "u":
                guard index < characters.count, characters[index] == "{" else {
                    throw ScriptError.invalidEscape("u", start)
                }
                index += 1
                let begin = index
                while index < characters.count, characters[index] != "}" { index += 1 }
                guard index < characters.count else { throw ScriptError.unexpectedEnd(start) }
                let hex = String(characters[begin..<index])
                index += 1
                guard let scalarValue = UInt32(hex, radix: 16), let scalar = UnicodeScalar(scalarValue) else {
                    throw ScriptError.invalidEscape("u{\(hex)}", start)
                }
                return Character(String(scalar))
            default:
                throw ScriptError.invalidEscape(String(escaped), start)
            }
        }

        func location() -> ScriptSourceLocation {
            let prefix = characters.prefix(index)
            let line = prefix.reduce(into: 1) { count, character in
                if character == "\n" { count += 1 }
            }
            let lastNewline = prefix.lastIndex(of: "\n")
            let column = index - (lastNewline.map { prefix.distance(from: prefix.startIndex, to: $0) + 1 } ?? 0) + 1
            return ScriptSourceLocation(offset: index, line: line, column: column)
        }
    }
}

public struct ScriptContext: Codable, Sendable, Equatable {
    public var metadata: Metadata
    public var variables: [String: [String]]
    public var multiValueSeparator: String
    public var now: Date

    public init(
        metadata: Metadata = Metadata(),
        variables: [String: [String]] = [:],
        multiValueSeparator: String = "; ",
        now: Date = Date()
    ) {
        self.metadata = metadata
        self.variables = variables.reduce(into: [:]) { result, item in
            result[item.key.lowercased()] = item.value
        }
        self.multiValueSeparator = multiValueSeparator
        self.now = now
    }

    public func values(for name: String) -> [String] {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if metadata.contains(key) { return metadata.values(for: key) }
        return variables[key] ?? []
    }
}

public struct ScriptEvaluation: Codable, Sendable, Equatable {
    public let output: String
    public let metadata: Metadata
    public let variables: [String: [String]]

    public init(output: String, metadata: Metadata, variables: [String: [String]]) {
        self.output = output
        self.metadata = metadata
        self.variables = variables
    }
}

public struct ScriptEvaluator: Sendable {
    private let parser: ScriptParser

    public init(parser: ScriptParser = ScriptParser()) {
        self.parser = parser
    }

    public func evaluate(_ source: String, context: ScriptContext = ScriptContext()) throws -> ScriptEvaluation {
        let program = try parser.parse(source)
        var context = context
        let value = try evaluateSequence(program.nodes, context: &context)
        return ScriptEvaluation(output: value.rendered(separator: context.multiValueSeparator), metadata: context.metadata, variables: context.variables)
    }

    private struct Value: Sendable, Equatable {
        var values: [String]

        init(_ values: [String] = []) { self.values = values }
        init(_ value: String) { self.values = [value] }

        var first: String { values.first ?? "" }
        var isEmpty: Bool { values.allSatisfy(\.isEmpty) }

        func rendered(separator: String) -> String {
            values.joined(separator: separator)
        }
    }

    private func evaluateSequence(_ nodes: [ScriptNode], context: inout ScriptContext) throws -> Value {
        guard nodes.count != 1 else {
            return try evaluate(nodes[0], context: &context)
        }
        var output = String()
        for node in nodes {
            output += try evaluate(node, context: &context).rendered(separator: context.multiValueSeparator)
        }
        return Value(output)
    }

    private func evaluate(_ node: ScriptNode, context: inout ScriptContext) throws -> Value {
        switch node {
        case let .sequence(nodes):
            return try evaluateSequence(nodes, context: &context)
        case let .literal(value, _):
            return Value(value)
        case let .variable(name, _):
            return Value(context.values(for: name))
        case let .function(name, arguments, location):
            let values = try arguments.map { try evaluate($0, context: &context) }
            return try evaluateFunction(name: name.lowercased(), arguments: values, location: location, context: &context)
        }
    }

    private func evaluateFunction(
        name: String,
        arguments: [Value],
        location: ScriptSourceLocation,
        context: inout ScriptContext
    ) throws -> Value {
        func argument(_ index: Int, required: Bool = true) throws -> Value {
            guard index < arguments.count else {
                if required { throw ScriptError.invalidArgument(function: name, message: "missing argument", location: location) }
                return Value()
            }
            return arguments[index]
        }

        func string(_ index: Int, required: Bool = true) throws -> String {
            try argument(index, required: required).rendered(separator: context.multiValueSeparator)
        }

        func integer(_ index: Int) throws -> Int {
            let raw = try string(index)
            guard let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw ScriptError.invalidNumber(raw, location)
            }
            return value
        }

        switch name {
        case "noop", "copy":
            return try argument(1, required: false).values.isEmpty ? argument(0, required: false) : argument(1, required: false)
        case "get":
            return Value(context.values(for: try string(0)))
        case "set":
            let key = try string(0).lowercased()
            let value = try argument(1)
            context.metadata.setValues(value.values, for: key)
            return value
        case "setmulti", "addmulti":
            let key = try string(0).lowercased()
            let newValues = arguments.dropFirst().flatMap(\.values)
            if name == "setmulti" {
                context.metadata.setValues(newValues, for: key)
            } else {
                for value in newValues { context.metadata.appendUniqueValue(value, for: key) }
            }
            return Value(newValues)
        case "unset":
            let key = try string(0)
            context.metadata.unset(key)
            return Value()
        case "delete":
            let key = try string(0)
            context.metadata.delete(key)
            return Value()
        case "lower", "lowercase":
            return Value((try string(0)).lowercased())
        case "upper", "uppercase":
            return Value((try string(0)).uppercased())
        case "capitalize":
            return Value((try string(0)).capitalized)
        case "trim":
            return Value((try string(0)).trimmingCharacters(in: .whitespacesAndNewlines))
        case "replace":
            return Value((try string(0)).replacingOccurrences(of: try string(1), with: try string(2, required: false)))
        case "rreplace":
            let input = try string(0)
            let pattern = try string(1)
            let replacement = try string(2, required: false)
            do {
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(input.startIndex..<input.endIndex, in: input)
                return Value(regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: replacement))
            } catch {
                throw ScriptError.invalidRegularExpression(pattern, location)
            }
        case "substr":
            let input = Array(try string(0))
            let start = max(0, min(input.count, try integer(1)))
            let end = arguments.count > 2 ? max(start, min(input.count, try integer(2))) : input.count
            return Value(String(input[start..<end]))
        case "left":
            let input = Array(try string(0))
            let count = max(0, min(input.count, try integer(1)))
            return Value(String(input.prefix(count)))
        case "right":
            let input = Array(try string(0))
            let count = max(0, min(input.count, try integer(1)))
            return Value(String(input.suffix(count)))
        case "len", "length":
            return Value(String((try string(0)).count))
        case "pad":
            let input = try string(0)
            let width = try integer(1)
            let fill = String((try string(2, required: false)).first ?? "0")
            return Value(input.count >= width ? input : String(repeating: fill, count: width - input.count) + input)
        case "num":
            let input = try string(0)
            let width = try integer(1)
            guard let number = Int(input.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw ScriptError.invalidNumber(input, location)
            }
            return Value(String(format: "%0*d", width, number))
        case "first":
            return Value(try argument(0).values.first.map { [$0] } ?? [])
        case "last":
            return Value(try argument(0).values.last.map { [$0] } ?? [])
        case "join":
            let values = try argument(0).values
            let separator = try string(1, required: false)
            return Value(values.joined(separator: separator))
        case "unique":
            var seen = Set<String>()
            return Value(try argument(0).values.filter { seen.insert($0).inserted })
        case "sort":
            return Value(try argument(0).values.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        case "reverse":
            return Value(try argument(0).values.reversed())
        case "if":
            return truthy(try argument(0)) ? try argument(1, required: false) : try argument(2, required: false)
        case "if2", "if3", "if4", "if5":
            for value in arguments where !value.isEmpty { return value }
            return Value()
        case "and":
            return Value(arguments.allSatisfy(truthy) ? "1" : "")
        case "or":
            return Value(arguments.contains(where: truthy) ? "1" : "")
        case "not":
            return Value(truthy(try argument(0)) ? "" : "1")
        case "eq", "is":
            return Value((try string(0)).caseInsensitiveCompare(try string(1)) == .orderedSame ? "1" : "")
        case "ne", "isnt":
            return Value((try string(0)).caseInsensitiveCompare(try string(1)) == .orderedSame ? "" : "1")
        case "contains":
            return Value((try string(0)).localizedCaseInsensitiveContains(try string(1)) ? "1" : "")
        case "startswith":
            return Value((try string(0)).lowercased().hasPrefix(try string(1).lowercased()) ? "1" : "")
        case "endswith":
            return Value((try string(0)).lowercased().hasSuffix(try string(1).lowercased()) ? "1" : "")
        case "gt", "lt", "gte", "lte":
            let left = try Double(string(0)) ?? Double(integer(0))
            let right = try Double(string(1)) ?? Double(integer(1))
            let result: Bool = switch name {
            case "gt": left > right
            case "lt": left < right
            case "gte": left >= right
            default: left <= right
            }
            return Value(result ? "1" : "")
        case "add", "sub", "mul", "div", "mod":
            let left = try integer(0)
            let right = try integer(1)
            let result: Int
            switch name {
            case "add": result = left + right
            case "sub": result = left - right
            case "mul": result = left * right
            case "div":
                guard right != 0 else { throw ScriptError.invalidArgument(function: name, message: "division by zero", location: location) }
                result = left / right
            default:
                guard right != 0 else { throw ScriptError.invalidArgument(function: name, message: "division by zero", location: location) }
                result = left % right
            }
            return Value(String(result))
        case "year", "month", "day":
            let calendar = Calendar(identifier: .gregorian)
            let component: Calendar.Component = switch name {
            case "year": .year
            case "month": .month
            default: .day
            }
            return Value(String(calendar.component(component, from: context.now)))
        case "datetime":
            let format = try string(0, required: false)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format.isEmpty ? "yyyy-MM-dd HH:mm:ss" : format
            return Value(formatter.string(from: context.now))
        case "initials":
            return Value((try string(0)).split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).compactMap(\.first).map(String.init).joined())
        case "swapprefix":
            let value = try string(0)
            let prefix = try string(1, required: false)
            let replacement = try string(2, required: false)
            guard !prefix.isEmpty, value.lowercased().hasPrefix(prefix.lowercased()) else { return Value(value) }
            return Value(replacement + value.dropFirst(prefix.count))
        default:
            throw ScriptError.unknownFunction(name, location)
        }
    }

    private func truthy(_ value: Value) -> Bool {
        guard let first = value.values.first else { return false }
        let normalized = first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalized.isEmpty && normalized != "0" && normalized != "false" && normalized != "no"
    }
}
