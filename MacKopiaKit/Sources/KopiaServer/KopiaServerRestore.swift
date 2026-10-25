import Foundation

extension KopiaServerClient {
    package func editSnapshot(id: String, description: String, pinned: Bool) async throws -> KopiaSnapshot {
        struct Request: Encodable {
            let snapshots: [String]
            let description: String
            let addPins: [String]
            let removePins: [String]
        }
        // Kopia 0.23.1: edits replace manifest IDs. Only the user pin is removed; safety pins stay intact.
        let pin = "mackopia-user"
        let body = try JSONEncoder().encode(
            Request(
                snapshots: [id], description: description,
                addPins: pinned ? [pin] : [], removePins: pinned ? [] : [pin]))
        let data = try await read(.editSnapshots, method: "POST", body: body)
        let items = try JSONDecoder().decode([KopiaSnapshot].self, from: data)
        guard items.count == 1, let item = items.first, item.id != nil,
            item.description == description, (item.pins?.contains(pin) == true) == pinned
        else {
            throw KopiaServerClientError.response
        }
        return item
    }

    package func startRestore(root: String, destination: String) async throws -> KopiaTask {
        struct Output: Encodable {
            let targetPath: String
            let overwriteFiles = false, overwriteDirectories = false, overwriteSymlinks = false
            let writeFilesAtomically = true
        }
        struct Options: Encodable {
            let restoreDirEntryAtDepth = Int32.max
            let deleteExtra = false, ignoreErrors = false
        }
        struct Request: Encodable { let root: String; let fsOutput: Output; let options = Options() }
        let body = try JSONEncoder().encode(Request(root: root, fsOutput: Output(targetPath: destination)))
        let data = try await read(.restore, method: "POST", body: body)
        return try JSONDecoder().decode(KopiaTask.self, from: data)
    }

    package func cancelTask(id: String) async throws {
        _ = try await read(.cancelTask(id), method: "POST", body: Data("{}".utf8))
    }

}
