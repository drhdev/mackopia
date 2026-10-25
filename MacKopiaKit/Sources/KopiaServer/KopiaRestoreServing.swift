import Foundation

package protocol KopiaRestoreServing: KopiaBackupServing {
    func directory(id: String) async throws -> KopiaDirectory
    func task(id: String) async throws -> KopiaTask
    func startRestore(root: String, destination: String) async throws -> KopiaTask
    func editSnapshot(id: String, description: String, pinned: Bool) async throws -> KopiaSnapshot
    func cancelTask(id: String) async throws
}
