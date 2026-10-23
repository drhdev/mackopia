import Foundation

/// Memory-only payload. Deliberately neither Codable nor printable through reflection.
package struct SecretValue: Sendable, CustomReflectable, CustomStringConvertible, CustomDebugStringConvertible {
    package let data: Data

    package init(data: Data) throws {
        guard !data.isEmpty, data.count <= 65_536 else { throw SecretStoreError.invalidValue }
        self.data = data
    }

    package var customMirror: Mirror { Mirror(self, children: [:]) }
    package var description: String { "<redacted secret>" }
    package var debugDescription: String { description }
}
