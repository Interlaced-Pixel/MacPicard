import Foundation

public struct Metadata: Codable, Sendable, Equatable {
    private var fields: [String: [String]]
    private var deletedKeys: Set<String>

    public init(
        fields: [String: [String]] = [:],
        deletedKeys: Set<String> = []
    ) {
        self.fields = [:]
        self.deletedKeys = Set(deletedKeys.map(Self.normalizeKey))

        for (key, values) in fields {
            let normalizedKey = Self.normalizeKey(key)
            guard !normalizedKey.isEmpty else {
                continue
            }
            self.fields[normalizedKey] = values
        }
    }

    public var keys: [String] {
        fields.keys.sorted()
    }

    public var deletedTagKeys: Set<String> {
        deletedKeys
    }

    public var isEmpty: Bool {
        fields.isEmpty && deletedKeys.isEmpty
    }

    public subscript(key: String) -> [String] {
        get {
            values(for: key)
        }
        set {
            setValues(newValue, for: key)
        }
    }

    public func values(for key: String) -> [String] {
        fields[Self.normalizeKey(key)] ?? []
    }

    public func firstValue(for key: String) -> String? {
        values(for: key).first
    }

    public func contains(_ key: String) -> Bool {
        fields[Self.normalizeKey(key)] != nil
    }

    public func isDeleted(_ key: String) -> Bool {
        deletedKeys.contains(Self.normalizeKey(key))
    }

    public mutating func setValues(_ values: [String], for key: String) {
        let normalizedKey = Self.normalizeKey(key)
        guard !normalizedKey.isEmpty else {
            return
        }

        if values.isEmpty {
            fields.removeValue(forKey: normalizedKey)
        } else {
            fields[normalizedKey] = values
        }
        deletedKeys.remove(normalizedKey)
    }

    public mutating func setValue(_ value: String, for key: String) {
        setValues([value], for: key)
    }

    public mutating func appendValue(_ value: String, for key: String) {
        let normalizedKey = Self.normalizeKey(key)
        guard !normalizedKey.isEmpty else {
            return
        }

        fields[normalizedKey, default: []].append(value)
        deletedKeys.remove(normalizedKey)
    }

    public mutating func appendUniqueValue(_ value: String, for key: String) {
        let normalizedKey = Self.normalizeKey(key)
        guard !values(for: normalizedKey).contains(value) else {
            return
        }
        appendValue(value, for: normalizedKey)
    }

    public mutating func unset(_ key: String) {
        let normalizedKey = Self.normalizeKey(key)
        fields.removeValue(forKey: normalizedKey)
        deletedKeys.remove(normalizedKey)
    }

    public mutating func delete(_ key: String) {
        let normalizedKey = Self.normalizeKey(key)
        guard !normalizedKey.isEmpty else {
            return
        }
        fields.removeValue(forKey: normalizedKey)
        deletedKeys.insert(normalizedKey)
    }

    public mutating func clear() {
        fields.removeAll(keepingCapacity: false)
        deletedKeys.removeAll(keepingCapacity: false)
    }

    public func difference(from original: Metadata) -> MetadataDiff {
        let keys = Set(original.fields.keys)
            .union(fields.keys)
            .union(original.deletedKeys)
            .union(deletedKeys)

        let changes = keys.sorted().compactMap { key -> MetadataChange? in
            let originalValues = original.values(for: key)
            let currentValues = values(for: key)
            let originalDeleted = original.isDeleted(key)
            let currentDeleted = isDeleted(key)

            guard originalValues != currentValues || originalDeleted != currentDeleted else {
                return nil
            }

            return MetadataChange(
                key: key,
                originalValues: originalValues,
                currentValues: currentValues,
                originalDeleted: originalDeleted,
                currentDeleted: currentDeleted
            )
        }

        return MetadataDiff(changes: changes)
    }

    public func applying(_ diff: MetadataDiff) -> Metadata {
        var result = self

        for change in diff.changes {
            if change.currentDeleted {
                result.delete(change.key)
            } else if change.currentValues.isEmpty {
                result.setValues([], for: change.key)
            } else {
                result.setValues(change.currentValues, for: change.key)
            }
        }

        return result
    }

    public func rawFields() -> [String: [String]] {
        fields
    }

    private static func normalizeKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public struct MetadataChange: Codable, Sendable, Equatable, Identifiable {
    public let key: String
    public let originalValues: [String]
    public let currentValues: [String]
    public let originalDeleted: Bool
    public let currentDeleted: Bool

    public var id: String { key }

    public init(
        key: String,
        originalValues: [String],
        currentValues: [String],
        originalDeleted: Bool,
        currentDeleted: Bool
    ) {
        self.key = key
        self.originalValues = originalValues
        self.currentValues = currentValues
        self.originalDeleted = originalDeleted
        self.currentDeleted = currentDeleted
    }
}

public struct MetadataDiff: Codable, Sendable, Equatable {
    public let changes: [MetadataChange]

    public init(changes: [MetadataChange] = []) {
        self.changes = changes
    }

    public var isEmpty: Bool {
        changes.isEmpty
    }

    public var changedKeys: [String] {
        changes.map(\.key)
    }
}
