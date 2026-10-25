import BackupDomain
import Foundation
import Testing

@testable import KopiaCLI

struct KopiaFilesystemBindingTests {
    @Test(arguments: ["valid", "path", "identity", "backend", "actions", "symlink"])
    func isolatedConfigurationMustMatchDestinationAndDisableActions(change: String) throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Repository(
            name: "Test", kind: .filesystem(path: root.appendingPathComponent("storage").path, volume: nil),
            identity: SnapshotIdentity(overrideUser: "user", overrideHost: "host"), secretRef: SecretRef())
        let paths = try KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: root)
        try FileManager.default.createDirectory(
            at: paths.configurationDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let path = paths.configurationDirectory.appendingPathComponent("repository.config")
        let document: [String: Any] = [
            "storage": [
                "type": change == "backend" ? "s3" : "filesystem",
                "config": [
                    "path": root.appendingPathComponent(change == "path" ? "other" : "storage").path,
                    "fileMode": 384, "dirMode": 448, "dirShards": NSNull(),
                ],
            ],
            "username": change == "identity" ? "other" : "user", "hostname": "host",
            "enableActions": change == "actions",
        ]
        let data = try JSONSerialization.data(withJSONObject: document)
        try data.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        if change == "symlink" {
            let moved = root.appendingPathComponent("moved")
            try FileManager.default.moveItem(at: path, to: moved)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: moved)
        }
        if change == "valid" {
            try KopiaFilesystemBinding.validate(repository: repository, homeDirectory: root)
        } else {
            #expect(throws: KopiaProcessError.invalidRequest) {
                try KopiaFilesystemBinding.validate(repository: repository, homeDirectory: root)
            }
        }
    }
}
