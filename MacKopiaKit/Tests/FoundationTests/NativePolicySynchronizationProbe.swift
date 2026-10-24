import BackupDomain
import Foundation
import Testing

@testable import BackupEngine
@testable import KopiaServer

/// Runs in the existing real-Kopia integration fixture; all paths belong to its disposable repository.
enum NativePolicySynchronizationProbe {
    static func run(client: KopiaServerClient, source: URL, root: URL, selector: KopiaSnapshotSource) async throws {
        // Exercise the complete production policy path, including native exclusion resolution.
        let volumeUUID = try #require(source.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        let sourceModel = try BackupSource(
            path: source.path,
            volume: VolumeIdentity(uuid: volumeUUID, name: "Temporary", isRemovable: false, isNetwork: false))
        let plan = try SourcePolicySynchronizerTests().plan(
            source: sourceModel, patterns: ["*.tmp", "!keep.tmp"], defaults: true, timeMachine: true)
        var initial = try #require(try await client.policyDefinition(source: selector)).document
        try initial.updateSection("retention", values: ["ignoreIdenticalSnapshots": Data("true".utf8)])
        try initial.updateSection("files", values: ["ignoreDotFiles": Data(#"[".customignore"]"#.utf8)])
        try await client.replacePolicy(source: selector, document: initial)
        let synchronizer = SourcePolicySynchronizer(
            service: client, timeMachineResolver: try TimeMachineExclusionResolver())
        let identity = try SnapshotIdentity(overrideUser: "test-user", overrideHost: "test-host")
        #expect(
            try await synchronizer.synchronize(
                plan: plan, source: sourceModel, identity: identity, homeDirectory: root.path))
        #expect(
            try await !synchronizer.synchronize(
                plan: plan, source: sourceModel, identity: identity, homeDirectory: root.path))
        let synchronized = try #require(try await client.policyDefinition(source: selector))
        let projection = try JSONDecoder().decode(KopiaPolicy.self, from: synchronized.document.encoded())
        #expect(projection.retention?.keepLatest == 0)
        #expect(projection.retention?.keepDaily == 7)
        #expect(projection.retention?.keepAnnual == nil)
        #expect(projection.retention?.ignoreIdenticalSnapshots == true)
        #expect(projection.files?.ignoreDotFiles == [".customignore"])
        #expect(projection.compression?.compressorName == "none")
        #expect(projection.files?.noParentIgnore == true)
        #expect(projection.files?.ignoreCacheDirs == false)
        #expect(projection.files?.oneFileSystem == true)
        let parent = try KopiaSnapshotSource(userName: "test-user", host: "test-host", path: root.path)
        try await client.replacePolicy(
            source: parent, document: KopiaPolicyDocument(data: Data(#"{"files":{"maxFileSize":1}}"#.utf8)))
        await #expect(throws: PolicySynchronizationError.effectiveMismatch) {
            try await synchronizer.synchronize(
                plan: plan, source: sourceModel, identity: identity, homeDirectory: root.path)
        }
        let unchanged = try #require(try await client.policyDefinition(source: selector))
        #expect(try unchanged.document.equivalent(to: synchronized.document))
    }
}
