import BackupDomain
import Foundation
import Testing

@testable import BackupEngine

struct MacOSExclusionPatternsTests {
    private let home = "/Users/test-user"
    private let common = [".Trash/", ".DS_Store", ".Spotlight-V100/", ".fseventsd/"]
    private let trailing = [".cache/", "*.tmp", "*.swp"]

    private func patterns(_ path: String, home: String = "/Users/test-user") throws -> [String] {
        let source = try BackupSource(
            path: path,
            volume: VolumeIdentity(uuid: UUID().uuidString, name: "Test", isRemovable: false, isNetwork: false))
        return try MacOSExclusionPatterns.resolve(for: source, homeDirectory: home)
    }

    @Test func versionOneContainsOnlyMandatoryDefaultsInStableOrder() throws {
        let result = try patterns(home)
        #expect(MacOSExclusionPatterns.version == 1)
        #expect(
            result == common + [
                "/Library/Caches/", "/Library/Logs/", "/Library/Containers/*/Data/Library/Caches/",
                "/Library/Developer/Xcode/DerivedData/", "/Library/Developer/CoreSimulator/Caches/",
                "/Library/Mobile Documents/", "/Library/CloudStorage/",
            ] + trailing)
        #expect(try result == patterns(home))
        #expect(!result.contains(where: { $0.contains("MobileSync") || $0.contains("node_modules") }))
    }

    @Test(arguments: ["/Documents", "/Users/test-user/Documents", "/Users/test-user-old", "/Users/other/Library"])
    func unrelatedDirectoriesNeverReceiveHomeLibraryRules(path: String) throws {
        #expect(try patterns(path) == common + trailing)
    }

    @Test func projectsPatternsIntoAncestorAndDescendantSources() throws {
        #expect(try patterns("/").contains("/Users/test-user/Library/Caches/"))
        #expect(try patterns("/Users").contains("/test-user/Library/Caches/"))
        let library = try patterns(home + "/Library")
        #expect(library.contains("/Caches/"))
        #expect(library.contains("/Containers/*/Data/Library/Caches/"))
        #expect(!library.contains("/Library/Caches/"))
        #expect(
            try patterns(home + "/Library/Containers/app.example/Data/Library")
                == common + ["/Caches/"] + trailing)
    }

    @Test(arguments: [
        "Library/Caches", "Library/Caches/nested", "Library/Mobile Documents",
        "Library/CloudStorage/Provider/Documents", "Library/Containers/app.example/Data/Library/Caches",
    ])
    func explicitlyExcludesAllEntriesWhenSourceIsInsideExcludedDirectory(relative: String) throws {
        #expect(try patterns(home + "/" + relative) == ["**"])
    }

    @Test func pathComponentBoundariesAndCaseRemainExact() throws {
        #expect(try patterns(home + "/Library/Caches-old") == common + trailing)
        #expect(try patterns(home + "/library") == common + trailing)
        #expect(try patterns(home + "/Library/Containers/app/Data/Library/Caches-old") == common + trailing)
    }

    @Test func escapesLiteralHomeGlobCharactersAndPreservesUnicode() throws {
        let result = try patterns("/Users", home: "/Users/Grüße [x]*?\\")
        #expect(result.contains("/Grüße \\[x\\]\\*\\?\\\\/Library/Caches/"))
        #expect(result.contains("/Grüße \\[x\\]\\*\\?\\\\/Library/Containers/*/Data/Library/Caches/"))
        #expect(try patterns("/Users/Grüße ax", home: "/Users/Grüße [x]*?\\") == common + trailing)
    }

    @Test func translatesResolvedDefaultsBeforeUserNegations() throws {
        let source = try BackupSource(
            path: home,
            volume: VolumeIdentity(uuid: UUID().uuidString, name: "Test", isRemovable: false, isNetwork: false))
        let plan = try BackupPlan(
            name: "Test", isEnabled: true, repositoryID: UUID(), sources: [source], triggers: [.manual],
            conditions: RunConditions(
                requiresACPower: false, skipOnExpensiveNetwork: false, skipOnConstrainedNetwork: false),
            retention: RetentionPolicy(preset: .balanced),
            excludes: ExcludeRules(
                useMacOSDefaults: true, honorTimeMachineExclusions: false, ignoreCacheDirs: true,
                patterns: ["!/Library/Logs/", "custom/"]),
            options: PlanOptions(compression: .zstd, lowPriority: true, ejectVolumeAfterBackup: false),
            health: HealthThresholds())
        let resolved = try MacOSExclusionPatterns.resolve(for: source, homeDirectory: home)
        let translated = try PolicyTranslator.translate(plan: plan, source: source, macOSPatterns: resolved)
        #expect(translated.ignore == resolved + ["!/Library/Logs/", "custom/"])
        #expect(translated.ignoreCacheDirs)
    }

    @Test(arguments: [
        "relative", "/Users/../test-user", "/Users//test-user", "/Users/test-user/", "/bad\nname", "/bad\0name",
    ])
    func rejectsAmbiguousOrUnrepresentableHomePaths(home: String) throws {
        #expect(throws: DomainValidationError.self) {
            try patterns("/", home: home)
        }
    }
}
