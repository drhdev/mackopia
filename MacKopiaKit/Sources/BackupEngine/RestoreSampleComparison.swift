import Darwin
import Foundation
import KopiaCLI

/// The only output name is locally generated inside a private directory. Snapshot names are read-only inputs.
struct RestoreSampleComparison {
    /// Nil: ineligible original. False: original changed during restore. Neither is success evidence.
    static func compare(
        sourcePath: String, sample: KopiaRestoreSample, temporaryDirectory: URL,
        restore: @Sendable (URL) async throws -> Void
    ) async throws -> Bool? {
        guard let root = RestoreFileFingerprint.rootComponents(path: sourcePath) else { return nil }
        let components = root + sample.components
        guard let original = try RestoreFileFingerprint.read(components: components),
            original.size == sample.size,
            abs(original.modifiedAt.timeIntervalSince(sample.modifiedAt)) < 0.000_001
        else { return nil }
        let directory = try makeTemporaryDirectory(in: temporaryDirectory)
        do {
            let destination = directory.appendingPathComponent("sample")
            try await restore(destination)
            try Task.checkCancellation()
            guard let outputRoot = RestoreFileFingerprint.rootComponents(path: directory.path) else {
                throw BackupOperationError.operationFailed
            }
            let restored = try RestoreFileFingerprint.read(components: outputRoot + ["sample"])
            let current = try RestoreFileFingerprint.read(components: components)
            // A concurrent source edit makes the comparison inconclusive, never corruption evidence.
            guard current == original else {
                try FileManager.default.removeItem(at: directory)
                return false
            }
            guard let restored, restored.size == sample.size, restored.digest == original.digest else {
                throw BackupOperationError.operationFailed
            }
            try FileManager.default.removeItem(at: directory)
            return true
        } catch {
            // Cleanup is synchronous and remains mandatory during task cancellation.
            try FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func makeTemporaryDirectory(in parent: URL) throws -> URL {
        var template = Array(
            parent.resolvingSymlinksInPath().appendingPathComponent("mackopia-test-restore-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw BackupOperationError.operationFailed }
        return URL(
            fileURLWithPath: String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self),
            isDirectory: true)
    }
}
