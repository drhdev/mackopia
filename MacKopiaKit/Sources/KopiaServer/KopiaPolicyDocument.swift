import Foundation

/// Complete local definition with opaque JSON values, never an effective-policy projection.
/// Unknown values retain their original bytes (including large numbers); object key order is canonicalized.
package struct KopiaPolicyDocument: Sendable, Equatable, CustomReflectable {
    package static let maximumBytes = 1_048_576
    private var fields: [String: Data]

    package init(data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw KopiaPolicyMergeError.invalidDocument }
        do {
            // Check structure/depth before Foundation parses it; retain raw values rather than its numeric projections.
            var scanner = PolicyJSONScanner(bytes: Array(data))
            try scanner.scanValue()
            scanner.skipWhitespace()
            guard scanner.index == scanner.bytes.count else { throw KopiaPolicyMergeError.invalidDocument }
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            fields = try Self.object(data)
            for name in ["retention", "files", "compression", "scheduling"] {
                if let section = fields[name], section != Data("null".utf8) {
                    _ = try Self.object(section)
                }
            }
        } catch { throw KopiaPolicyMergeError.invalidDocument }
    }

    package init() { fields = [:] }

    package func encoded() throws -> Data {
        let data = try Self.encodeObject(fields)
        guard data.count <= Self.maximumBytes else { throw KopiaPolicyMergeError.invalidDocument }
        return data
    }

    package var customMirror: Mirror { Mirror(self, children: ["policyDocument": "<private>"]) }

    package func value(for name: String) -> Data? { fields[name] }

    /// Compare JSON objects independent of key order without rounding opaque numeric tokens.
    package func equivalent(to other: Self) throws -> Bool {
        try Self.canonical(encoded()) == Self.canonical(other.encoded())
    }

    /// Kopia 0.23.1 emits empty struct sections, but omits empty ignore lists and zero maxFileSize.
    /// Optional false/zero values remain significant. Unknown fields are never discarded here.
    package func equivalentStoredDefinition(to other: Self) throws -> Bool {
        try normalized().equivalent(to: other.normalized())
    }

    private func normalized() throws -> Self {
        var result = self
        if let data = fields["files"], data != Data("null".utf8) {
            var files = try Self.object(data)
            if let ignore = files["ignore"], try Self.canonical(ignore) == Data("[]".utf8) {
                files["ignore"] = nil
            }
            if files["maxFileSize"] == Data("0".utf8) { files["maxFileSize"] = nil }
            result.fields["files"] = try Self.encodeObject(files)
        }
        for name in [
            "retention", "files", "errorHandling", "scheduling", "compression", "metadataCompression",
            "splitter", "actions", "upload",
        ] {
            if let data = result.fields[name], try Self.canonical(data) == Data("{}".utf8) {
                result.fields[name] = nil
            }
        }
        for (name, empty) in [
            "osSnapshots": #"{"volumeShadowCopy":{}}"#,
            "logging": #"{"directories":{},"entries":{}}"#,
        ] {
            if let data = result.fields[name],
                try Self.canonical(data) == Self.canonical(Data(empty.utf8))
            {
                result.fields[name] = nil
            }
        }
        return result
    }

    private static func canonical(_ data: Data) throws -> Data {
        var scanner = PolicyJSONScanner(bytes: Array(data))
        scanner.skipWhitespace()
        if scanner.bytes[scanner.index] == 123 {
            return try encodeObject(object(data).mapValues { try canonical($0) })
        }
        if scanner.consume(91) {
            var values: [Data] = []
            scanner.skipWhitespace()
            while !scanner.consume(93) {
                let start = scanner.index
                try scanner.scanValue()
                values.append(try canonical(Data(scanner.bytes[start..<scanner.index])))
                scanner.skipWhitespace()
                if scanner.consume(44) { scanner.skipWhitespace() } else { break }
            }
            return Data("[".utf8)
                + values.reduce(into: Data()) { result, value in
                    if !result.isEmpty { result.append(44) }
                    result.append(value)
                } + Data("]".utf8)
        }
        if scanner.bytes[scanner.index] == 34 {
            return try JSONEncoder().encode(JSONDecoder().decode(String.self, from: data))
        }
        return Data(data.filter { ![9, 10, 13, 32].contains($0) })
    }

    /// Missing and null sections both represent an unset Kopia struct. Other non-object values are rejected.
    package mutating func updateSection(_ name: String, values: [String: Data?]) throws {
        var section: [String: Data] = [:]
        if let existing = fields[name], existing != Data("null".utf8) {
            section = try Self.object(existing)
        }
        for (key, value) in values { section[key] = value }
        fields[name] = try Self.encodeObject(section)
    }

    private static func object(_ data: Data) throws -> [String: Data] {
        var scanner = PolicyJSONScanner(bytes: Array(data))
        scanner.skipWhitespace()
        guard scanner.consume(123) else { throw KopiaPolicyMergeError.invalidDocument }
        scanner.skipWhitespace()
        var result: [String: Data] = [:]
        if scanner.consume(125) { return result }
        while true {
            let keyStart = scanner.index
            try scanner.scanString()
            let key = try JSONDecoder().decode(String.self, from: Data(scanner.bytes[keyStart..<scanner.index]))
            scanner.skipWhitespace()
            guard scanner.consume(58) else { throw KopiaPolicyMergeError.invalidDocument }
            scanner.skipWhitespace()
            let start = scanner.index
            try scanner.scanValue()
            guard result[key] == nil else { throw KopiaPolicyMergeError.invalidDocument }
            result[key] = Data(scanner.bytes[start..<scanner.index])
            scanner.skipWhitespace()
            if scanner.consume(125) { return result }
            guard scanner.consume(44) else { throw KopiaPolicyMergeError.invalidDocument }
            scanner.skipWhitespace()
        }
    }

    private static func encodeObject(_ fields: [String: Data]) throws -> Data {
        var result = Data("{".utf8)
        for (index, key) in fields.keys.sorted().enumerated() {
            if index > 0 { result.append(44) }
            result.append(try JSONEncoder().encode(key))
            result.append(58)
            if let value = fields[key] { result.append(value) }
        }
        result.append(125)
        return result
    }
}

/// Only locates JSON boundaries; Foundation validates JSON grammar afterwards.
private struct PolicyJSONScanner {
    let bytes: [UInt8]
    var index = 0

    mutating func skipWhitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    mutating func scanString() throws {
        guard consume(34) else { throw KopiaPolicyMergeError.invalidDocument }
        while index < bytes.count {
            if consume(34) { return }
            if consume(92) {
                guard index < bytes.count else { throw KopiaPolicyMergeError.invalidDocument }
            }
            index += 1
        }
        throw KopiaPolicyMergeError.invalidDocument
    }

    mutating func scanValue(depth: Int = 0) throws {
        skipWhitespace()
        guard depth < 64, index < bytes.count else { throw KopiaPolicyMergeError.invalidDocument }
        switch bytes[index] {
        case 34: try scanString()
        case 123, 91:
            let close: UInt8 = bytes[index] == 123 ? 125 : 93
            index += 1
            while index < bytes.count {
                skipWhitespace()
                if consume(close) { return }
                if consume(44) || consume(58) { continue }
                try scanValue(depth: depth + 1)
            }
            throw KopiaPolicyMergeError.invalidDocument
        default:
            let start = index
            while index < bytes.count, ![9, 10, 13, 32, 44, 58, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw KopiaPolicyMergeError.invalidDocument }
        }
    }
}
