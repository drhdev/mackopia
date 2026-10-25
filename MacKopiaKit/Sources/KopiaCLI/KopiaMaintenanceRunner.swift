import Foundation

/// The service holds its shared reservation after checking the current owner and full schedule.
package struct KopiaMaintenanceRunner: Sendable {
    private let process: any KopiaProcessRunning

    package init() { process = KopiaProcess() }
    init(process: any KopiaProcessRunning) { self.process = process }

    package func runFull(
        executable: URL, paths: KopiaRepositoryPaths, temporaryDirectory: URL,
        user: String, backupPassword: String, lowPriority: Bool, s3: KopiaS3Authentication? = nil
    ) async throws {
        try Task.checkCancellation()
        let context = KopiaExecutionContext(
            executable: executable, paths: paths, temporaryDirectory: temporaryDirectory,
            user: user, configuration: .file, backupPassword: backupPassword, s3: s3)
        // Kopia 0.23.1: retain the CLI's owner, locking and safety defaults; never force maintenance.
        var request = context.request(for: .maintenanceFull)
        request.lowPriority = lowPriority
        request.timeout = .seconds(6 * 60 * 60)
        let result = try await process.run(request)
        try Task.checkCancellation()
        guard result.exitCode == 0 else { throw KopiaProcessError.commandFailed(exitCode: result.exitCode) }
    }
}
