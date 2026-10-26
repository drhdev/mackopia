import Foundation

/// Bounded inspection and single-file restore; the owner supplies the protected repository context.
package struct KopiaRestoreSampler: Sendable {
    private let process: any KopiaProcessRunning
    package init() { process = KopiaProcess() }
    init(process: any KopiaProcessRunning) { self.process = process }

    package func samples(
        rootID: String, executable: URL, paths: KopiaRepositoryPaths, temporaryDirectory: URL,
        user: String, backupPassword: String, lowPriority: Bool, s3: KopiaS3Authentication? = nil, webDAV: Data? = nil
    ) async throws -> [KopiaRestoreSample] {
        guard Self.validObjectID(rootID) else { throw KopiaProcessError.invalidRequest }
        let context = KopiaExecutionContext(
            executable: executable, paths: paths, temporaryDirectory: temporaryDirectory,
            user: user, configuration: webDAV.map { .webDAV($0) } ?? .file, backupPassword: backupPassword, s3: s3)
        var pending: [(String, [String])] = [(rootID, [])]
        var visited = Set<String>()
        var result: [KopiaRestoreSample] = []
        var count = 0
        // Bounds deliberately permit an inconclusive check on very large trees, never fabricated success.
        while let (id, components) = pending.popLast(), visited.count < 256 {
            try Task.checkCancellation()
            guard visited.insert(id).inserted else { continue }
            var request = context.request(for: .showObject(id))
            request.lowPriority = lowPriority
            let output = try await process.run(request)
            guard output.exitCode == 0 else { throw KopiaProcessError.commandFailed(exitCode: output.exitCode) }
            let directory = try JSONDecoder().decode(Directory.self, from: output.standardOutput)
            guard directory.stream == "kopia:directory" else { throw KopiaProcessError.invalidRequest }
            for entry in directory.entries ?? [] {
                count += 1
                guard count <= 10_000 else { return result }
                guard Self.validComponent(entry.name) else { throw KopiaProcessError.invalidRequest }
                guard entry.type == "f" || entry.type == "d" else { continue }
                guard let objectID = entry.obj, Self.validObjectID(objectID) else {
                    throw KopiaProcessError.invalidRequest
                }
                let path = components + [entry.name]
                if entry.type == "d", path.count < 32 { pending.append((objectID, path)) }
                let size = entry.size ?? 0
                guard entry.type == "f", size >= 0, size < 50_000_000,
                    let mtime = entry.mtime, let date = Self.date(mtime)
                else { continue }
                result.append(KopiaRestoreSample(components: path, objectID: objectID, size: size, modifiedAt: date))
            }
        }
        return result
    }

    package func restore(
        _ sample: KopiaRestoreSample, to destination: URL, executable: URL, paths: KopiaRepositoryPaths,
        temporaryDirectory: URL, user: String, backupPassword: String, lowPriority: Bool,
        s3: KopiaS3Authentication? = nil, webDAV: Data? = nil
    ) async throws {
        guard Self.validObjectID(sample.objectID), destination.isFileURL, destination.path.hasPrefix("/") else {
            throw KopiaProcessError.invalidRequest
        }
        let context = KopiaExecutionContext(
            executable: executable, paths: paths, temporaryDirectory: temporaryDirectory,
            user: user, configuration: webDAV.map { .webDAV($0) } ?? .file, backupPassword: backupPassword, s3: s3)
        // Kopia 0.23.1: atomic writes plus skipped permissions retain 0600 for a raw file-object restore.
        // Default non-atomic restore would create 0644, unsuitable for private temporary backup content.
        var request = context.request(for: .restoreSample(objectID: sample.objectID, destination: destination.path))
        request.lowPriority = lowPriority
        request.timeout = .seconds(10 * 60)
        let result = try await process.run(request)
        guard result.exitCode == 0 else { throw KopiaProcessError.commandFailed(exitCode: result.exitCode) }
        try Task.checkCancellation()
    }

    static func validObjectID(_ value: String) -> Bool {
        // Kopia 0.23.1: directory IDs have k, indirect file IDs can have I as a prefix.
        var hex = value[...]
        if hex.first == "k" { hex = hex.dropFirst() }
        if hex.first == "I" { hex = hex.dropFirst() }
        return value.count <= 66 && (hex.count == 32 || hex.count == 64)
            && hex.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
            && value.utf8.count <= 255
    }

    private static func date(_ value: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) { return date }
        return try? Date.ISO8601FormatStyle().parse(value)
    }

    struct Directory: Decodable {
        let stream: String
        let entries: [Entry]?
    }
    struct Entry: Decodable {
        let name: String
        let type: String
        let obj: String?
        let size: Int64?
        let mtime: String?
    }
}
