import Foundation

/// Pure local-definition merge. This does not resolve inheritance or authorize a policy write.
package enum SourcePolicyMerger {
    package static func merge(
        _ desired: TranslatedSourcePolicy, into existing: KopiaPolicyDocument
    ) throws -> KopiaPolicyDocument {
        var result = existing
        let retention = desired.retention
        // Kopia 0.23.1 OptionalInt: nil removes the local override (inherits); zero is an explicit override.
        try result.updateSection(
            "retention",
            values: [
                "keepLatest": try encode(retention.keepLatest), "keepHourly": try encode(retention.keepHourly),
                "keepDaily": try encode(retention.keepDaily), "keepWeekly": try encode(retention.keepWeekly),
                "keepMonthly": try encode(retention.keepMonthly), "keepAnnual": try encode(retention.keepAnnual),
            ])
        try result.updateSection(
            "files",
            values: [
                "ignore": try JSONEncoder().encode(desired.ignore),
                "noParentIgnore": Data("true".utf8),
                "ignoreCacheDirs": try JSONEncoder().encode(desired.ignoreCacheDirs),
                "maxFileSize": try encode(desired.maxFileSize),
                "oneFileSystem": try JSONEncoder().encode(desired.oneFileSystem),
            ])
        try result.updateSection(
            "compression", values: ["compressorName": try JSONEncoder().encode(desired.compression.rawValue)])
        // Kopia 0.23.1: an empty ignore list and maxFileSize zero still inherit in MergePolicies.
        // noParentIgnore controls traversal, not mergeStringList. Do not change root noParent: doing so
        // would also discard unrelated inherited policy. A writer must inspect resolved policy first.
        // Scheduling is deliberately preserved byte-for-byte; this merger never enables/disables it.
        _ = try result.encoded()
        return result
    }

    private static func encode<T: Encodable>(_ value: T?) throws -> Data? {
        try value.map { try JSONEncoder().encode($0) }
    }
}
