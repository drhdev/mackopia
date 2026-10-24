import BackupDomain
import Foundation
import KopiaServer

/// One instance per repository session, used inside the existing protected operation reservation.
/// No plan-hash cache: inherited policies and resolved exclusions can change independently of the plan.
package actor SourcePolicySynchronizer {
    private let service: any KopiaPolicyServing
    private let timeMachineResolver: TimeMachineExclusionResolver
    private let now: @Sendable () -> ContinuousClock.Instant
    private var active = false

    package init(
        service: any KopiaPolicyServing, timeMachineResolver: TimeMachineExclusionResolver,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.service = service
        self.timeMachineResolver = timeMachineResolver
        self.now = now
    }

    /// Returns true only when a write was necessary. This never starts snapshots or applies retention.
    /// A failed/cancelled PUT has an uncertain outcome; no rollback or automatic retry is attempted.
    package func synchronize(
        plan: BackupPlan, source: BackupSource, identity: SnapshotIdentity, homeDirectory: String
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard !active else { throw PolicySynchronizationError.busy }
        guard plan.sources.contains(source) else { throw DomainValidationError.invalidPlan }
        active = true
        defer { active = false }
        let macOS =
            try plan.excludes.useMacOSDefaults
            ? MacOSExclusionPatterns.resolve(for: source, homeDirectory: homeDirectory) : nil
        let timeMachine =
            try await plan.excludes.honorTimeMachineExclusions
            ? timeMachineResolver.resolve(for: source, oneFileSystem: plan.excludes.oneFileSystem) : nil
        let desired = try PolicyTranslator.translate(
            plan: plan, source: source, macOSPatterns: macOS,
            timeMachinePatterns: timeMachine?.patterns(for: source, now: now()))
        let selector = try KopiaSnapshotSource(
            userName: identity.overrideUser, host: identity.overrideHost, path: source.path)
        let original = try await definition(selector)
        let candidate = try SourcePolicyMerger.merge(desired, into: original ?? KopiaPolicyDocument())
        try EffectiveSourcePolicyValidator.validateScheduling(candidate)
        let expected = try await service.previewPolicy(source: selector, updates: candidate)
        try EffectiveSourcePolicyValidator.validate(expected, desired: desired)

        // Kopia 0.23.1 has no conditional PUT/ETag. Recheck parents and local definition, then
        // verify after writing. An external process can still race; do not claim atomic conflict protection.
        let fresh = try await service.previewPolicy(source: selector, updates: candidate)
        let current = try await definition(selector)
        guard try expected.equivalent(to: fresh), try same(original, current) else {
            throw PolicySynchronizationError.conflict
        }
        try Task.checkCancellation()
        _ = try timeMachine?.patterns(for: source, now: now())
        let changed = try !(original?.equivalentStoredDefinition(to: candidate) ?? false)
        if changed { try await service.replacePolicy(source: selector, document: candidate) }
        try Task.checkCancellation()
        guard let stored = try await definition(selector), try stored.equivalentStoredDefinition(to: candidate) else {
            throw PolicySynchronizationError.verificationFailed
        }
        let actual = try await service.previewPolicy(source: selector, updates: nil)
        try EffectiveSourcePolicyValidator.validate(actual, desired: desired)
        guard try expected.equivalent(to: actual) else { throw PolicySynchronizationError.conflict }
        _ = try timeMachine?.patterns(for: source, now: now())
        return changed
    }

    private func definition(_ selector: KopiaSnapshotSource) async throws -> KopiaPolicyDocument? {
        guard let value = try await service.policyDefinition(source: selector) else { return nil }
        guard value.source == selector else { throw PolicySynchronizationError.conflict }
        return value.document
    }

    private func same(_ lhs: KopiaPolicyDocument?, _ rhs: KopiaPolicyDocument?) throws -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): true
        case (.some(let lhs), .some(let rhs)): try lhs.equivalent(to: rhs)
        default: false
        }
    }
}
