import BackupDomain
import Foundation
import Testing

@testable import BackupEngine

struct PolicyTranslatorTests {
    private func source(path: String = "/Synthetic Source") throws -> BackupSource {
        try BackupSource(
            path: path,
            volume: VolumeIdentity(uuid: UUID().uuidString, name: "Test", isRemovable: false, isNetwork: false))
    }

    private func plan(
        source: BackupSource, retention: RetentionPolicy? = nil,
        compression: Compression = .zstd, defaults: Bool = false, timeMachine: Bool = false,
        patterns: [String] = [], cache: Bool = false, maxMB: Int? = nil, oneFileSystem: Bool = false
    ) throws -> BackupPlan {
        try BackupPlan(
            name: "Test", isEnabled: true, repositoryID: UUID(), sources: [source], triggers: [.manual],
            conditions: RunConditions(
                requiresACPower: false, skipOnExpensiveNetwork: false, skipOnConstrainedNetwork: false),
            retention: retention ?? RetentionPolicy(preset: .balanced),
            excludes: ExcludeRules(
                useMacOSDefaults: defaults, honorTimeMachineExclusions: timeMachine, ignoreCacheDirs: cache,
                patterns: patterns, maxFileSizeMB: maxMB, oneFileSystem: oneFileSystem),
            options: PlanOptions(compression: compression, lowPriority: true, ejectVolumeAfterBackup: false),
            health: HealthThresholds())
    }

    @Test(arguments: [RetentionPreset.balanced, .spaceSaving, .maximum])
    func preservesEveryRetentionPreset(preset: RetentionPreset) throws {
        let source = try source()
        let retention = try RetentionPolicy(preset: preset)
        let plan = try plan(source: source, retention: retention)
        let result = try PolicyTranslator.translate(plan: plan, source: source)
        #expect(result.retention == retention)
        #expect(result.source == source)
        #expect(try result == PolicyTranslator.translate(plan: plan, source: source))
    }

    @Test(arguments: Compression.allCases)
    func preservesCompressionNilZeroAndFalse(compression: Compression) throws {
        let source = try source()
        let retention = try RetentionPolicy(keepLatest: 0, keepDaily: 7, keepAnnual: 0)
        let result = try PolicyTranslator.translate(
            plan: plan(source: source, retention: retention, compression: compression), source: source)
        #expect(result.compression == compression)
        #expect(result.retention.keepLatest == 0)
        #expect(result.retention.keepHourly == nil)
        #expect(result.retention.keepDaily == 7)
        #expect(result.retention.keepAnnual == 0)
        #expect(result.ignore.isEmpty)
        #expect(!result.ignoreCacheDirs)
        #expect(!result.oneFileSystem)
        #expect(result.maxFileSize == nil)
    }

    @Test func preservesPatternOrderNegationsUnicodeAndRepetitions() throws {
        let source = try source()
        let plan = try plan(
            source: source, defaults: true, timeMachine: true,
            patterns: ["!Library/Caches/keep", "Privat ü/", "*.tmp"], cache: true, maxMB: 12, oneFileSystem: true)
        let result = try PolicyTranslator.translate(
            plan: plan, source: source, macOSPatterns: ["Library/Caches/", "*.tmp"],
            timeMachinePatterns: ["Excluded Folder/"])
        #expect(
            result.ignore == [
                "Library/Caches/", "*.tmp", "Excluded Folder/", "!Library/Caches/keep", "Privat ü/", "*.tmp",
            ])
        #expect(result.ignoreCacheDirs)
        #expect(result.oneFileSystem)
        #expect(result.maxFileSize == 12_000_000)
        let reflected = String(reflecting: result)
        #expect(!reflected.contains("Privat"))
        #expect(!reflected.contains(source.path))
    }

    @Test func activatedResolversMustCompleteEvenWhenNoMatchesExist() throws {
        let source = try source()
        for flags in [(true, false), (false, true), (true, true)] {
            let plan = try plan(source: source, defaults: flags.0, timeMachine: flags.1)
            #expect(throws: DomainValidationError.invalidPlan) {
                try PolicyTranslator.translate(plan: plan, source: source)
            }
            if flags.0 && flags.1 {
                #expect(throws: DomainValidationError.invalidPlan) {
                    try PolicyTranslator.translate(plan: plan, source: source, macOSPatterns: [])
                }
                #expect(throws: DomainValidationError.invalidPlan) {
                    try PolicyTranslator.translate(plan: plan, source: source, timeMachinePatterns: [])
                }
            }
            #expect(
                try PolicyTranslator.translate(
                    plan: plan, source: source, macOSPatterns: [], timeMachinePatterns: []
                ).ignore.isEmpty)
        }
        let disabled = try plan(source: source, patterns: ["User/"])
        #expect(
            try PolicyTranslator.translate(
                plan: disabled, source: source, macOSPatterns: ["Generated/"], timeMachinePatterns: ["Other/"]
            ).ignore == ["User/"])
    }

    @Test func rejectsForeignSourceAndChangedSourceIdentity() throws {
        let source = try source()
        let plan = try plan(source: source)
        // The same path on another volume or with another source UUID is insufficient.
        let changed = try BackupSource(id: source.id, path: "/Changed", volume: source.volume)
        for foreign in [try self.source(), try self.source(path: "/Other"), changed] {
            #expect(throws: DomainValidationError.invalidPlan) {
                try PolicyTranslator.translate(plan: plan, source: foreign)
            }
        }
    }

    @Test func validatesGeneratedRulesAndCombinedResourceLimits() throws {
        let source = try source()
        let plan = try plan(source: source, defaults: true, timeMachine: true, patterns: ["User/"])
        for invalid in [[""], ["bad\nrule"], ["bad\rrule"], ["bad\0rule"], [String(repeating: "x", count: 16_385)]] {
            #expect(throws: DomainValidationError.invalidPlan) {
                try PolicyTranslator.translate(
                    plan: plan, source: source, macOSPatterns: invalid, timeMachinePatterns: [])
            }
        }
        for lists in [
            (Array(repeating: "x", count: 2048), Array(repeating: "y", count: 2048)),
            (
                Array(repeating: String(repeating: "x", count: 16_384), count: 32),
                Array(repeating: String(repeating: "y", count: 16_384), count: 32)
            ),
        ] {
            #expect(throws: DomainValidationError.invalidPlan) {
                try PolicyTranslator.translate(
                    plan: plan, source: source, macOSPatterns: lists.0, timeMachinePatterns: lists.1)
            }
        }
    }

    @Test func convertsLargestDomainByteLimitWithoutOverflow() throws {
        let source = try source()
        let megabytes = Int.max / 1_000_000
        let result = try PolicyTranslator.translate(plan: plan(source: source, maxMB: megabytes), source: source)
        #expect(result.maxFileSize == Int64(megabytes) * 1_000_000)
    }
}
