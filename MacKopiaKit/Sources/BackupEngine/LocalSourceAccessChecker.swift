import BackupDomain
import SystemIntegration

/// Explicit opt-in only: the agent must establish the protected-data probe's process attribution.
/// Conservatively requires protected-data evidence for all sources, avoiding a path-prefix allowlist
/// that would miss protected descendants of a home directory or a symlinked source.
package struct LocalSourceAccessChecker: SourceAccessChecking {
    private let fullDiskAccess: any FullDiskAccessProbing
    private let reader: any ReadAccessProbing

    package init(fullDiskAccess: any FullDiskAccessProbing, reader: any ReadAccessProbing = LocalReadAccessProbe()) {
        self.fullDiskAccess = fullDiskAccess
        self.reader = reader
    }

    package func checkAccess(to sources: [BackupSource]) async throws -> PreflightAccessStatus {
        try Task.checkCancellation()
        guard !sources.isEmpty else { return .unknown }
        let protectedAccess = try await fullDiskAccess.probe()
        try Task.checkCancellation()
        switch protectedAccess {
        case .denied: return .denied
        case .unknown: return .unknown
        case .readable: break
        }
        for source in sources {
            let access = try await reader.readDirectory(at: source.path)
            try Task.checkCancellation()
            switch access {
            case .readable: continue
            case .denied: return .denied
            case .missing, .unknown: return .unknown
            }
        }
        return .verified
    }
}
