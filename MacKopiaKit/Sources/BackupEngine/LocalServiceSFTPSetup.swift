import BackupDomain
import Foundation
import KopiaCLI
import Secrets

extension LocalBackupService {
    public func setupSFTP(name: String, source: BackupSource, setup: SFTPSetup, create: Bool) async throws {
        try setup.validate()
        let setup = try await KopiaSFTPSetup.normalize(setup, home: home, temporary: temporary)
        guard source.bookmark == nil, !create || setup.backupPassword.count >= 12 else {
            throw LocalServiceIssue.invalidRequest
        }
        try await mutate {
            try await self.performSFTPSetup(name: name, source: source, setup: setup, create: create)
        }
    }

    public func updateSFTPCredentials(repositoryID: UUID, setup: SFTPSetup) async throws {
        try setup.validate()
        let setup = try await KopiaSFTPSetup.normalize(setup, home: home, temporary: temporary)
        try await mutate {
            guard let repository = await self.configuration?.repositories.first(where: { $0.id == repositoryID }),
                repository.kind == setup.kind
            else { throw LocalServiceIssue.invalidRequest }
            // Probe the replacement first. Invalid credentials never replace a working Keychain item.
            let payload = try KopiaSFTPSetup.configuration(repository: repository, home: self.home, setup: setup)
            try await self.gate.withOperation(repositoryID: repositoryID) {
                try KopiaFilesystemBinding.validate(repository: repository, homeDirectory: self.home)
                let paths = try KopiaRepositoryPaths(repositoryID: repositoryID, homeDirectory: self.home)
                try await KopiaBinaryVerifier(
                    executable: self.executable, paths: paths,
                    temporaryDirectory: self.temporary, expectedVersion: self.version
                ).verify()
                let probe = try await KopiaRepositoryProbe().check(
                    executable: self.executable, paths: paths,
                    temporaryDirectory: self.temporary, user: NSUserName(), password: setup.backupPassword,
                    webDAV: payload)
                guard probe else { throw LocalServiceIssue.destination }
                do {
                    try await self.secrets.write(
                        SecretValue(data: JSONEncoder().encode(setup)), for: repository.secretRef)
                } catch { throw LocalServiceIssue.keychain }
            }
            await self.clearSFTPIssue(repositoryID)
        }
    }

    private func clearSFTPIssue(_ repositoryID: UUID) {
        for plan in configuration?.plans.filter({ $0.repositoryID == repositoryID }) ?? [] {
            planIssues.removeValue(forKey: plan.id)
        }
        if issue != .safeMode && issue != .automationUnavailable { issue = planIssues.values.first }
    }

    private func performSFTPSetup(name: String, source: BackupSource, setup: SFTPSetup, create: Bool) async throws {
        guard let config = configuration else { throw LocalServiceIssue.safeMode }
        guard !config.repositories.contains(where: { setup.identifies($0.kind) || $0.secretRef == setup.keyRef }) else {
            throw LocalServiceIssue.destination
        }
        let sourceURL = URL(fileURLWithPath: source.path).resolvingSymlinksInPath()
        try source.volume.requireMatch(uuid: volume(sourceURL).uuid)
        guard sourceURL.path == source.path else { throw LocalServiceIssue.destination }
        let repository = try Repository(
            name: name, kind: setup.kind,
            identity: config.repositories.first?.identity
                ?? SnapshotIdentity(
                    overrideUser: NSUserName(), overrideHost: ProcessInfo.processInfo.hostName), secretRef: setup.keyRef
        )
        let plan = try LocalPlanFactory.make(name: name, source: source, repositoryID: repository.id)
        _ = try await BackupPathPreflight().validate(plan: plan, repository: repository)
        let updated = try BackupConfiguration(
            repositories: config.repositories + [repository],
            plans: config.plans + [plan], notificationsEnabled: config.notificationsEnabled)
        let paths = try KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: home)
        try await KopiaBinaryVerifier(
            executable: executable, paths: paths, temporaryDirectory: temporary,
            expectedVersion: version
        ).verify()
        do {
            try await secrets.write(SecretValue(data: JSONEncoder().encode(setup)), for: repository.secretRef)
        } catch { throw LocalServiceIssue.keychain }
        do {
            try await gate.withOperation(repositoryID: repository.id) {
                try await self.protection.withProtection(sources: plan.sources, repository: repository) {
                    _ = try await BackupPathPreflight().validate(plan: plan, repository: repository)
                    try await KopiaSFTPSetup(
                        executable: self.executable, home: self.home, temporary: self.temporary,
                        user: NSUserName()
                    ).perform(
                        repository: repository, setup: setup, create: create)
                }
            }
            try Task.checkCancellation()
            try await persist(updated)
        } catch {
            // A failed/uncertain publish never removes remote data or potentially committed credentials.
            if error as? LocalServiceIssue == .safeMode { throw LocalServiceIssue.safeMode }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            issue = .destination
            throw LocalServiceIssue.destination
        }
    }
}
