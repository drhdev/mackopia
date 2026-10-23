import Foundation

package enum DomainValidation {
    package static func volumeUUID(_ value: String) -> UUID? {
        // Foundation's UUID parser can accept a valid UUID followed by a NUL; require the full canonical input.
        guard value.utf8.count == 36, let uuid = UUID(uuidString: value),
            uuid.uuidString.lowercased() == value.lowercased()
        else { return nil }
        return uuid
    }

    static func text(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= limit && !value.utf8.contains(0)
    }

    package static func absolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= 16_384, !path.utf8.contains(0) else { return false }
        if path == "/" { return true }
        // Reject ambiguous persisted identities rather than silently resolving or normalizing user paths.
        return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
