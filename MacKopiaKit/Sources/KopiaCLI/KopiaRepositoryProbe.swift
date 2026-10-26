import Foundation

/// Authenticated read without a config-mutating connect or a persistent server.
package struct KopiaRepositoryProbe: Sendable {
    private let process: any KopiaProcessRunning
    package init() { process = KopiaProcess() }
    init(process: any KopiaProcessRunning) { self.process = process }
    package func check(
        executable: URL, paths: KopiaRepositoryPaths, temporaryDirectory: URL,
        user: String, password: String, authentication: KopiaS3Authentication? = nil, webDAV: Data? = nil
    ) async throws -> Bool {
        let context = KopiaExecutionContext(
            executable: executable, paths: paths, temporaryDirectory: temporaryDirectory,
            user: user, configuration: webDAV.map { .webDAV($0) } ?? .file, backupPassword: password, s3: authentication
        )
        var request = context.request(for: .repositoryStatus)
        request.timeout = .seconds(60)
        do {
            guard try await process.run(request).exitCode == 0 else { return false }
            // Kopia 0.23.1 can cache repository metadata. A fresh format-blob read must also authenticate.
            request = context.request(for: .repositoryAccess)
            request.timeout = .seconds(60)
            let result = try await process.run(request)
            return result.exitCode == 0 && !result.standardOutput.isEmpty
        } catch KopiaProcessError.timedOut {
            // Kopia 0.23.1 retries WebDAV authentication failures; a deadline is no proof of access.
            try Task.checkCancellation()
            return false
        }
    }
}
