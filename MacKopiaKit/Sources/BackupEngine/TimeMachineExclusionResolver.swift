import BackupDomain
import Foundation
import SystemIntegration

/// A reusable result is bound to the complete source, including bookmark and volume identity.
package struct TimeMachineExclusionSnapshot: Sendable, CustomReflectable {
    package var customMirror: Mirror { Mirror(self, children: ["snapshot": "<private>"]) }

    private let source: BackupSource
    private let patterns: [String]
    private let observedAt: ContinuousClock.Instant

    fileprivate init(source: BackupSource, patterns: [String], observedAt: ContinuousClock.Instant) {
        self.source = source
        self.patterns = patterns
        self.observedAt = observedAt
    }

    package func patterns(for source: BackupSource, now: ContinuousClock.Instant = .now) throws -> [String] {
        let age = observedAt.duration(to: now)
        guard self.source == source, age >= .zero, age <= .seconds(60) else {
            throw TimeMachineExclusionError.staleResult
        }
        return patterns
    }
}

/// Scans root plus three descendant levels. Any unreadable entry invalidates the entire result.
/// The deadline is cooperative around filesystem calls; a blocked kernel call can exceed it.
package struct TimeMachineExclusionResolver: Sendable {
    private let inspector: any TimeMachineExclusionInspecting
    private let now: @Sendable () -> ContinuousClock.Instant
    private let timeout: Duration
    private let entryLimit: Int

    package init(
        inspector: any TimeMachineExclusionInspecting = TimeMachineLocalExclusionInspector(),
        timeout: Duration = .seconds(10), entryLimit: Int = 10_000,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) throws {
        guard timeout > .zero, timeout <= .seconds(10), entryLimit > 0, entryLimit <= 10_000 else {
            throw TimeMachineExclusionError.limitExceeded
        }
        self.inspector = inspector
        self.now = now
        self.timeout = timeout
        self.entryLimit = entryLimit
    }

    package func resolve(
        for source: BackupSource, oneFileSystem: Bool = true
    ) async throws -> TimeMachineExclusionSnapshot {
        // Coverage is deliberately confined to the stored volume; do not use this result for cross-volume backups.
        guard oneFileSystem else { throw TimeMachineExclusionError.invalidSource }
        let started = now()
        var pending: [(path: String, relative: [String], depth: Int)] = [(source.path, [], 0)]
        var visited = 0
        var patterns: [String] = []
        while let item = pending.popLast() {
            try checkBudget(since: started)
            visited += 1
            guard visited <= entryLimit else { throw TimeMachineExclusionError.limitExceeded }
            let entry = try await inspector.inspect(item.path)
            try checkBudget(since: started)
            if entry.isSymbolicLink {
                guard item.depth > 0 else { throw TimeMachineExclusionError.invalidSource }
                continue
            }
            if item.depth == 0 {
                try source.volume.requireMatch(uuid: entry.volumeUUID)
                guard entry.isDirectory else { throw TimeMachineExclusionError.invalidSource }
            } else if try canonicalVolume(entry.volumeUUID) != source.volume.uuid {
                // A foreign mount is never traversed, even if oneFileSystem is later disabled.
                continue
            }
            if entry.isExcluded {
                if item.depth == 0 { patterns = ["**"]; break }
                // Kopia 0.23.1: leading slash anchors literal, escaped components to this source.
                patterns.append(
                    "/" + item.relative.map(Self.escape).joined(separator: "/") + (entry.isDirectory ? "/" : ""))
                continue
            }
            guard entry.isDirectory, item.depth < 3 else { continue }
            let remaining = entryLimit - visited - pending.count
            guard remaining > 0 else { throw TimeMachineExclusionError.limitExceeded }
            let children = try await inspector.children(of: item.path, limit: remaining)
            try checkBudget(since: started)
            guard children.count <= remaining, Set(children).count == children.count else {
                throw TimeMachineExclusionError.limitExceeded
            }
            for name in children.reversed() {
                guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
                    !name.contains(where: { $0.isNewline || $0 == "\0" })
                else { throw TimeMachineExclusionError.invalidSource }
                pending.append(
                    (
                        item.path == "/" ? "/" + name : item.path + "/" + name,
                        item.relative + [name], item.depth + 1
                    ))
            }
        }
        try checkBudget(since: started)
        let validated = try ExcludeRules(
            useMacOSDefaults: false, honorTimeMachineExclusions: false, ignoreCacheDirs: false,
            patterns: patterns
        ).patterns
        return TimeMachineExclusionSnapshot(source: source, patterns: validated, observedAt: started)
    }

    private func checkBudget(since start: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        let elapsed = start.duration(to: now())
        guard elapsed >= .zero, elapsed < timeout else { throw TimeMachineExclusionError.limitExceeded }
    }

    private func canonicalVolume(_ value: String) throws -> String {
        guard let uuid = DomainValidation.volumeUUID(value) else { throw TimeMachineExclusionError.unavailable }
        return uuid.uuidString
    }

    private static func escape(_ value: String) -> String {
        value.reduce(into: "") { result, character in
            if "\\*?[]".contains(character) { result.append("\\") }
            result.append(character)
        }
    }
}
