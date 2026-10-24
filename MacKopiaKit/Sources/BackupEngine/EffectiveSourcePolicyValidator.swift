import Foundation
import KopiaServer

/// Validates Kopia's actual merge, rather than assuming local overrides defeat inheritance.
package enum EffectiveSourcePolicyValidator {
    package static func validate(_ document: KopiaPolicyDocument, desired: TranslatedSourcePolicy) throws {
        let effective: Projection
        do { effective = try JSONDecoder().decode(Projection.self, from: document.encoded()) } catch {
            throw PolicySynchronizationError.effectiveMismatch
        }
        try validateScheduling(document)
        let retention = desired.retention
        for (key, value) in [
            "keepLatest": retention.keepLatest, "keepHourly": retention.keepHourly,
            "keepDaily": retention.keepDaily, "keepWeekly": retention.keepWeekly,
            "keepMonthly": retention.keepMonthly, "keepAnnual": retention.keepAnnual,
        ] {
            if let value, effective.retention?[key] != value { throw PolicySynchronizationError.effectiveMismatch }
        }
        guard let files = effective.files,
            (files.ignore ?? []) == desired.ignore,
            files.noParentIgnore == true,
            files.ignoreCacheDirs == desired.ignoreCacheDirs,
            (files.maxFileSize ?? 0) == (desired.maxFileSize ?? 0),
            files.oneFileSystem == desired.oneFileSystem,
            effective.compression?.compressorName == desired.compression.rawValue
        else { throw PolicySynchronizationError.effectiveMismatch }
    }

    package static func validateScheduling(_ document: KopiaPolicyDocument) throws {
        guard let data = document.value(for: "scheduling"), data != Data("null".utf8) else { return }
        let scheduling: Scheduling
        do { scheduling = try JSONDecoder().decode(Scheduling.self, from: data) } catch {
            throw PolicySynchronizationError.schedulingEnabled
        }
        // Kopia 0.23.1: manual suppresses NextSnapshotTime, including inherited scheduling values.
        guard
            scheduling.manual == true
                || ((scheduling.intervalSeconds ?? 0) == 0 && (scheduling.timeOfDay ?? []).isEmpty
                    && (scheduling.cron ?? []).isEmpty)
        else { throw PolicySynchronizationError.schedulingEnabled }
    }

    private struct Projection: Decodable {
        struct Files: Decodable {
            let ignore: [String]?
            let noParentIgnore: Bool?
            let ignoreCacheDirs: Bool?
            let maxFileSize: Int64?
            let oneFileSystem: Bool?
        }
        // Retention/compression contain additional heterogeneous fields; decode only managed fields.
        struct Retention: Decodable {
            let keepLatest, keepHourly, keepDaily, keepWeekly, keepMonthly, keepAnnual: Int?
            subscript(key: String) -> Int? {
                switch key {
                case "keepLatest": keepLatest
                case "keepHourly": keepHourly
                case "keepDaily": keepDaily
                case "keepWeekly": keepWeekly
                case "keepMonthly": keepMonthly
                case "keepAnnual": keepAnnual
                default: nil
                }
            }
        }
        struct Compression: Decodable {
            let compressorName: String?
        }
        let retention: Retention?
        let files: Files?
        let compression: Compression?
    }

    private struct Scheduling: Decodable {
        struct TimeOfDay: Decodable { let hour: Int; let min: Int }
        let intervalSeconds: Int64?
        let timeOfDay: [TimeOfDay]?
        let cron: [String]?
        let manual: Bool?
    }
}
