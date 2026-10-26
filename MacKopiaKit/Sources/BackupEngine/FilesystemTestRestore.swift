import BackupDomain
import Foundation
import KopiaCLI
import Secrets

package protocol SnapshotTestRestoring: Sendable {
    /// False means no unchanged eligible original was available; it must never create success evidence.
    func testRestore(
        repository: Repository, sources: [BackupSource], run: JobRun, lowPriority: Bool
    ) async throws -> Bool
}

/// Performs a real single-file restore under the caller's repository reservation and volume protection.
package struct FilesystemTestRestore: SnapshotTestRestoring {
    private let executable: URL
    private let homeDirectory: URL
    private let temporaryDirectory: URL
    private let user: String
    private let secrets: any SecretStore

    package init(
        executable: URL, homeDirectory: URL, temporaryDirectory: URL, user: String, secrets: any SecretStore
    ) {
        self.executable = executable
        self.homeDirectory = homeDirectory
        self.temporaryDirectory = temporaryDirectory
        self.user = user
        self.secrets = secrets
    }

    package func testRestore(
        repository: Repository, sources: [BackupSource], run: JobRun, lowPriority: Bool
    ) async throws -> Bool {
        try Task.checkCancellation()
        let credentials = try await RepositoryCredentials.read(
            repository: repository, secrets: secrets, homeDirectory: homeDirectory)
        let password = credentials.password
        try KopiaFilesystemBinding.validate(repository: repository, homeDirectory: homeDirectory)
        let paths = try KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: homeDirectory)
        let sampler = KopiaRestoreSampler()
        for source in sources.shuffled() {
            guard let backup = run.sources.first(where: { $0.sourceID == source.id }) else {
                throw BackupOperationError.snapshotMissing
            }
            let samples = try await sampler.samples(
                rootID: backup.rootID, executable: executable, paths: paths,
                temporaryDirectory: temporaryDirectory, user: user, backupPassword: password, lowPriority: lowPriority,
                s3: credentials.s3, webDAV: credentials.webDAV)
            for sample in samples.shuffled() {
                let result = try await RestoreSampleComparison.compare(
                    sourcePath: source.path, sample: sample, temporaryDirectory: temporaryDirectory
                ) { destination in
                    try await sampler.restore(
                        sample, to: destination, executable: executable, paths: paths,
                        temporaryDirectory: temporaryDirectory, user: user,
                        backupPassword: password, lowPriority: lowPriority, s3: credentials.s3,
                        webDAV: credentials.webDAV)
                }
                if let result { return result }
            }
        }
        return false
    }
}
