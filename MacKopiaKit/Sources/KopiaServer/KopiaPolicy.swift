import Foundation

/// Read-only projection. Absent fields retain inheritance semantics, including nil versus zero/false.
/// Unknown fields are ignored; this incomplete projection must never be used to write a policy back.
struct KopiaPolicy: Decodable, Sendable, CustomReflectable {
    struct Retention: Decodable, Sendable {
        let keepLatest: Int?
        let keepHourly: Int?
        let keepDaily: Int?
        let keepWeekly: Int?
        let keepMonthly: Int?
        let keepAnnual: Int?
        let ignoreIdenticalSnapshots: Bool?
    }

    struct Files: Decodable, Sendable, CustomReflectable {
        let ignore: [String]?
        let noParentIgnore: Bool?
        let ignoreDotFiles: [String]?
        let noParentDotFiles: Bool?
        let ignoreCacheDirs: Bool?
        let maxFileSize: Int64?
        let oneFileSystem: Bool?

        var customMirror: Mirror { Mirror(self, children: ["files": "<private>"]) }
    }

    struct Compression: Decodable, Sendable, CustomReflectable {
        let compressorName: String?
        let onlyCompress: [String]?
        let neverCompress: [String]?
        let minSize: Int64?
        let maxSize: Int64?

        var customMirror: Mirror { Mirror(self, children: ["compression": "<private>"]) }
    }

    let retention: Retention?
    let files: Files?
    let compression: Compression?
    let noParent: Bool?

    var customMirror: Mirror { Mirror(self, children: ["policy": "<private>"]) }
}
