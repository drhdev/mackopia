import Foundation

/// Bounded incremental parsing. Unknown stderr is discarded, never returned for logging.
struct KopiaServerHandshakeParser: Sendable, CustomReflectable {
    private static let prefixes = [
        "SERVER ADDRESS", "SERVER CERT SHA256", "SERVER CERTIFICATE",
        "SERVER PASSWORD", "SERVER CONTROL PASSWORD",
    ]
    private var pending = Data()
    private var fields: [String: String] = [:]
    private var byteCount = 0
    private var failure: KopiaServerHandshakeError?
    private var completed = false

    var customMirror: Mirror { Mirror(self, children: [:]) }

    /// Feed only until a handshake is returned; the lifecycle must continue draining stderr afterwards.
    mutating func consume(_ bytes: Data) throws -> KopiaServerHandshake? {
        if let failure { throw failure }
        guard !completed else { throw KopiaServerHandshakeError.invalid }
        do {
            guard bytes.count <= 262_144 - byteCount else { throw KopiaServerHandshakeError.limitExceeded }
            byteCount += bytes.count
            for byte in bytes {
                if byte == 10 {
                    try consumeLine()
                    pending.removeAll(keepingCapacity: true)
                } else {
                    guard pending.count < 32_768 else { throw KopiaServerHandshakeError.limitExceeded }
                    pending.append(byte)
                }
            }
            if fields.count == Self.prefixes.count {
                let handshake = try KopiaServerHandshake(fields: fields)
                fields.removeAll()
                completed = true
                return handshake
            }
            return nil
        } catch let error as KopiaServerHandshakeError {
            failure = error
            pending.removeAll()
            fields.removeAll()
            throw error
        }
    }

    mutating func finish() throws {
        if let failure { throw failure }
        guard completed else {
            pending.removeAll()
            fields.removeAll()
            failure = .incomplete
            throw KopiaServerHandshakeError.incomplete
        }
    }

    private mutating func consumeLine() throws {
        guard let line = String(data: pending, encoding: .utf8) else { throw KopiaServerHandshakeError.invalid }
        // Kopia 0.23.1 writes these exact prefixes without a logging timestamp.
        for prefix in Self.prefixes where line.hasPrefix(prefix + ":") {
            guard line.hasPrefix(prefix + ": "), fields[prefix] == nil else {
                throw KopiaServerHandshakeError.invalid
            }
            let value = String(line.dropFirst(prefix.count + 2))
            guard !value.isEmpty, !value.utf8.contains(0), !value.utf8.contains(13) else {
                throw KopiaServerHandshakeError.invalid
            }
            fields[prefix] = value
        }
    }
}
