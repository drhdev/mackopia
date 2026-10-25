import BackupDomain
import Foundation

/// Only scheduling fields are retained; Kopia's run errors can contain private diagnostics.
package struct KopiaMaintenanceInfo: Sendable, CustomReflectable {
    package enum FullMaintenance: Sendable, Equatable {
        case ownerRequired, foreignOwner, disabled, due
        case scheduled(Date)
    }

    private let owner: String
    private let enabled: Bool
    private let nextFull: Date

    package init(data: Data) throws {
        do {
            let response = try JSONDecoder().decode(Response.self, from: data)
            guard response.owner.utf8.count <= 4096,
                !response.owner.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                response.full.interval > 0,
                let date = Self.date(response.schedule.nextFullMaintenance)
            else { throw KopiaProcessError.invalidRequest }
            owner = response.owner
            enabled = response.full.enabled
            nextFull = date
        } catch {
            // DecodingError can embed untrusted values or coding paths. Keep the boundary static.
            throw KopiaProcessError.invalidRequest
        }
    }

    package func fullMaintenance(identity: SnapshotIdentity, at date: Date) throws -> FullMaintenance {
        guard date.timeIntervalSinceReferenceDate.isFinite, date >= .distantPast, date <= .distantFuture else {
            throw KopiaProcessError.invalidRequest
        }
        guard !owner.isEmpty else { return .ownerRequired }
        guard owner == identity.overrideUser + "@" + identity.overrideHost else { return .foreignOwner }
        guard enabled else { return .disabled }
        // Kopia 0.23.1: a Go zero time means no schedule yet, hence immediately due.
        return nextFull <= date ? .due : .scheduled(nextFull)
    }

    package var customMirror: Mirror { Mirror(self, children: ["maintenance": "<private>"]) }

    private static func date(_ value: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) { return date }
        return try? Date.ISO8601FormatStyle().parse(value)
    }

    private struct Response: Decodable {
        struct Cycle: Decodable {
            let enabled: Bool
            // Kopia 0.23.1: time.Duration is encoded as an integer number of nanoseconds.
            let interval: Int64
        }
        struct Schedule: Decodable { let nextFullMaintenance: String }
        let owner: String
        let full: Cycle
        let schedule: Schedule
    }
}
