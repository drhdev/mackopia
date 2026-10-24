import BackupDomain
import Foundation

package enum PolicyTranslator {
    /// Resolved lists belong to this source. Nil means unresolved; an empty list means resolved with no matches.
    /// This function performs no filesystem access, scheduling, policy write or retention execution.
    package static func translate(
        plan: BackupPlan,
        source: BackupSource,
        macOSPatterns: [String]? = nil,
        timeMachinePatterns: [String]? = nil
    ) throws -> TranslatedSourcePolicy {
        guard plan.sources.contains(source),
            !plan.excludes.useMacOSDefaults || macOSPatterns != nil,
            !plan.excludes.honorTimeMachineExclusions || timeMachinePatterns != nil
        else { throw DomainValidationError.invalidPlan }

        // Preserve order and repetitions: user negations must remain after generated exclusions.
        let patterns =
            (plan.excludes.useMacOSDefaults ? macOSPatterns ?? [] : [])
            + (plan.excludes.honorTimeMachineExclusions ? timeMachinePatterns ?? [] : [])
            + plan.excludes.patterns
        // Apply the same resource limits to generated and user-provided rules together.
        let validated = try ExcludeRules(
            useMacOSDefaults: false, honorTimeMachineExclusions: false,
            ignoreCacheDirs: plan.excludes.ignoreCacheDirs, patterns: patterns,
            maxFileSizeMB: plan.excludes.maxFileSizeMB, oneFileSystem: plan.excludes.oneFileSystem)

        // Kopia 0.23.1 uses bytes for files.maxFileSize; the domain defines decimal MB.
        let maxFileSize: Int64?
        if let megabytes = validated.maxFileSizeMB {
            guard let value = Int64(exactly: megabytes) else { throw DomainValidationError.invalidPlan }
            let bytes = value.multipliedReportingOverflow(by: 1_000_000)
            guard !bytes.overflow else { throw DomainValidationError.invalidPlan }
            maxFileSize = bytes.partialValue
        } else {
            maxFileSize = nil
        }

        return TranslatedSourcePolicy(
            source: source, retention: plan.retention, compression: plan.options.compression,
            ignore: validated.patterns, ignoreCacheDirs: validated.ignoreCacheDirs,
            maxFileSize: maxFileSize, oneFileSystem: validated.oneFileSystem)
    }
}
