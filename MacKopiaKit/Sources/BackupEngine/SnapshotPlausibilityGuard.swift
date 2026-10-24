import BackupDomain
import Foundation
import KopiaServer

/// The caller holds the repository reservation through comparison, pinning and read-back.
package struct SnapshotPlausibilityGuard: Sendable {
    let service: any KopiaBackupServing

    static func baseline(_ snapshots: [KopiaSnapshot]) throws -> KopiaSnapshot? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seconds = ISO8601DateFormatter()
        var complete: [(Date, KopiaSnapshot)] = []
        for snapshot in snapshots where snapshot.incomplete == nil || snapshot.incomplete == "" {
            guard let start = snapshot.startTime, let end = snapshot.endTime,
                let started = formatter.date(from: start) ?? seconds.date(from: start),
                let ended = formatter.date(from: end) ?? seconds.date(from: end), started <= ended,
                let files = snapshot.summary?.files, files >= 0,
                let size = snapshot.summary?.size, size >= 0
            else { throw BackupOperationError.sourceResponseInvalid }
            complete.append((started, snapshot))
        }
        return complete.max {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            return ($0.1.id ?? "") < ($1.1.id ?? "")
        }?.1
    }

    /// Full-width products keep the strict percentage boundary exact even at Int64.max.
    static func dropped(previous: Int64, current: Int64, percent: Int) -> Bool {
        guard previous > 0, current >= 0, current < previous, (1...100).contains(percent) else { return false }
        let lhs = UInt64(current).multipliedFullWidth(by: 100)
        let rhs = UInt64(previous).multipliedFullWidth(by: UInt64(100 - percent))
        return lhs.high == rhs.high ? lhs.low < rhs.low : lhs.high < rhs.high
    }

    func protect(
        result: JobRun.SourceResult, snapshot: KopiaSnapshot, baseline: KopiaSnapshot?,
        source: KopiaSnapshotSource, previousIDs: Set<String>, percent: Int
    ) async -> JobRun.SourceResult {
        guard let baseline,
            Self.dropped(previous: baseline.summary?.files ?? 0, current: result.files, percent: percent)
                || Self.dropped(previous: baseline.summary?.size ?? 0, current: result.bytes, percent: percent)
        else { return result }
        var issues: [JobRun.Issue] = [.suspiciousSnapshot]
        var identifier = result.snapshotID
        // Kopia 0.23.1: edit replaces the manifest. Never retry a write after an ambiguous response;
        // recover the exact new manifest from this source, root and timestamp instead.
        do {
            let pinned = try await service.pinSnapshot(id: result.snapshotID)
            guard matches(pinned, original: snapshot, previousIDs: previousIDs) else {
                throw BackupOperationError.snapshotReferenceMissing
            }
            identifier = pinned.id ?? identifier
        } catch {
            // Read-back below can still prove a committed pin after a lost response.
        }
        do {
            let entries = try await service.snapshotManifests(source: source).snapshots ?? []
            let pinned = entries.filter { matches($0, original: snapshot, previousIDs: previousIDs) }
            guard pinned.count == 1, let id = pinned.first?.id else {
                throw BackupOperationError.snapshotReferenceMissing
            }
            identifier = id
        } catch { issues.append(.snapshotPinFailed) }
        return JobRun.SourceResult(
            sourceID: result.sourceID, snapshotID: identifier, rootID: result.rootID, bytes: result.bytes,
            files: result.files, errors: result.errors, ignoredErrors: result.ignoredErrors, issues: issues)
    }

    private func matches(_ pinned: KopiaSnapshot, original: KopiaSnapshot, previousIDs: Set<String>) -> Bool {
        guard let id = pinned.id, !id.isEmpty, !previousIDs.contains(id),
            original.startTime != nil, original.endTime != nil,
            pinned.startTime == original.startTime, pinned.endTime == original.endTime,
            pinned.rootID == original.rootID, pinned.summary?.files == original.summary?.files,
            pinned.summary?.size == original.summary?.size,
            pinned.incomplete == nil || pinned.incomplete == "",
            pinned.pins?.contains(KopiaServerClient.plausibilityPin) == true
        else { return false }
        return true
    }
}
