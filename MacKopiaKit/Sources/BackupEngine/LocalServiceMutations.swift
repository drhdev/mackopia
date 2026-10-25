import BackupDomain
import Foundation

extension LocalBackupService {
    public func setup(
        name: String, destination: BackupSource, source: BackupSource, password: String, create: Bool
    )
        async throws
    {
        try await mutate {
            try await self.performSetup(
                name: name, destination: destination, source: source, password: password, create: create)
        }
    }

    public func createPlan(name: String, repositoryID: UUID, source: BackupSource) async throws {
        try await mutate { try await self.performCreatePlan(name: name, repositoryID: repositoryID, source: source) }
    }

    public func savePlan(_ plan: BackupPlan) async throws {
        try await mutate { try await self.performSavePlan(plan) }
    }

    public func setNotificationsEnabled(_ enabled: Bool) async throws {
        try await mutate {
            guard let config = await self.configuration else { throw LocalServiceIssue.safeMode }
            try await self.persist(
                BackupConfiguration(
                    repositories: config.repositories, plans: config.plans,
                    notificationsEnabled: enabled))
        }
    }

    public func recoverConfiguration() async throws {
        guard !stopped else { throw LocalServiceIssue.unavailable }
        guard !mutating, active == nil, configuration == nil else { throw LocalServiceIssue.busy }
        mutating = true
        defer { mutating = false; changed() }
        await runtime?.shutdown()
        try await performRecoverConfiguration()
        try await startRuntime()
    }

    private func mutate(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        try availableForMutation()
        guard active == nil, let runtime else { throw LocalServiceIssue.busy }
        mutating = true
        defer { mutating = false; changed() }
        try await runtime.withConfigurationChange(operation)
    }
}

extension AutomaticBackupRuntime {
    /// Suspend automatic admission and dequeue before touching configuration or creating a destination.
    /// Existing backup work remains intact; setup/editor requests are rejected while it is active.
    func withConfigurationChange(_ operation: @Sendable () async throws -> Void) async throws {
        try await control(planID: nil) {
            do {
                guard await self.queue.activeJobs.isEmpty else { throw LocalServiceIssue.busy }
                try await operation()
                try await self.replaceConfiguration()
            } catch {
                if (try? await self.store.currentConfiguration()) == nil {
                    await self.configurationFailed()
                }
                throw error
            }
        }
    }
}
