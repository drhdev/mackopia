import Foundation

/// Authenticated read without a config-mutating connect or a persistent server.
package struct KopiaRepositoryProbe: Sendable {
    package init() {}
    package func check(
        executable: URL, paths: KopiaRepositoryPaths, temporaryDirectory: URL,
        user: String, password: String, authentication: KopiaS3Authentication
    ) async throws -> Bool {
        let context = KopiaExecutionContext(
            executable: executable, paths: paths, temporaryDirectory: temporaryDirectory,
            user: user, configuration: .file, backupPassword: password, s3: authentication)
        var request = context.request(for: .repositoryStatus)
        request.timeout = .seconds(60)
        guard try await KopiaProcess().run(request).exitCode == 0 else { return false }
        // Kopia 0.23.1 can cache repository metadata. A fresh format-blob read must also authenticate.
        request = context.request(for: .repositoryAccess)
        request.timeout = .seconds(60)
        let result = try await KopiaProcess().run(request)
        return result.exitCode == 0 && !result.standardOutput.isEmpty
    }
}
