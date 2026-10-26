import Foundation

/// The service must hold its shared repository reservation until this read finishes.
package struct KopiaMaintenanceReader: Sendable {
    private let process: any KopiaProcessRunning

    package init() { process = KopiaProcess() }
    init(process: any KopiaProcessRunning) { self.process = process }

    package func read(
        executable: URL, paths: KopiaRepositoryPaths, temporaryDirectory: URL,
        user: String, backupPassword: String, lowPriority: Bool, s3: KopiaS3Authentication? = nil, webDAV: Data? = nil
    ) async throws -> KopiaMaintenanceInfo {
        try Task.checkCancellation()
        let context = KopiaExecutionContext(
            executable: executable, paths: paths, temporaryDirectory: temporaryDirectory,
            user: user, configuration: webDAV.map { .webDAV($0) } ?? .file, backupPassword: backupPassword, s3: s3)
        var request = context.request(for: .maintenanceInfo)
        request.lowPriority = lowPriority
        let result = try await process.run(request)
        try Task.checkCancellation()
        guard result.exitCode == 0 else { throw KopiaProcessError.commandFailed(exitCode: result.exitCode) }
        return try KopiaMaintenanceInfo(data: result.standardOutput)
    }
}
