import Foundation

public struct ExcludeRules: Codable, Sendable, Hashable, CustomReflectable {
    public let useMacOSDefaults: Bool
    public let honorTimeMachineExclusions: Bool
    public let ignoreCacheDirs: Bool
    public let patterns: [String]
    public let maxFileSizeMB: Int?
    public let oneFileSystem: Bool

    public init(
        useMacOSDefaults: Bool,
        honorTimeMachineExclusions: Bool,
        ignoreCacheDirs: Bool,
        patterns: [String] = [],
        maxFileSizeMB: Int? = nil,
        oneFileSystem: Bool = true
    ) throws {
        guard patterns.count <= 4096,
            patterns.allSatisfy({
                DomainValidation.text($0, limit: 16_384)
                    && !$0.contains("\n") && !$0.contains("\r")
            }),
            patterns.reduce(0, { $0 + $1.utf8.count }) <= 1_048_576,
            maxFileSizeMB.map({ $0 > 0 && $0 <= Int.max / 1_000_000 }) ?? true
        else { throw DomainValidationError.invalidPlan }
        self.useMacOSDefaults = useMacOSDefaults
        self.honorTimeMachineExclusions = honorTimeMachineExclusions
        self.ignoreCacheDirs = ignoreCacheDirs
        self.patterns = patterns
        self.maxFileSizeMB = maxFileSizeMB
        self.oneFileSystem = oneFileSystem
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            useMacOSDefaults: c.decode(Bool.self, forKey: .useMacOSDefaults),
            honorTimeMachineExclusions: c.decode(Bool.self, forKey: .honorTimeMachineExclusions),
            ignoreCacheDirs: c.decode(Bool.self, forKey: .ignoreCacheDirs),
            patterns: c.decode([String].self, forKey: .patterns),
            maxFileSizeMB: c.decodeIfPresent(Int.self, forKey: .maxFileSizeMB),
            oneFileSystem: c.decode(Bool.self, forKey: .oneFileSystem))
    }

    public var customMirror: Mirror { Mirror(self, children: ["configuration": "<private>"]) }
}
