import CryptoKit
import Foundation
import Testing

@testable import BackupEngine

struct RestoreFileFingerprintTests {
    @Test func readsContentAndRejectsSymlinkAncestorsAndLeaves() throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("file")
        let content = Data("content".utf8)
        try content.write(to: file)
        let first = try #require(try read(file, root: root))
        #expect(first.digest == Data(SHA256.hash(data: content)))
        #expect(first.size == 7)
        #expect(try read(file, root: root) == first)
        let leaf = directory.appendingPathComponent("leaf")
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: file)
        #expect(try read(leaf, root: root) == nil)
        let ancestor = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: directory)
        #expect(try read(ancestor.appendingPathComponent("file"), root: root) == nil)
        #expect(try read(directory, root: root) == nil)
        #expect(try RestoreFileFingerprint.read(components: ["..", "private"]) == nil)
        try Data("changed".utf8).write(to: file)
        #expect(try read(file, root: root) != first)
    }

    @Test func exactSizeLimitAndCancellationAreEnforced() async throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large")
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 50_000_000)
        try handle.close()
        #expect(try read(file, root: root) == nil)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try read(file, root: root)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func read(_ url: URL, root: URL) throws -> RestoreFileFingerprint? {
        let canonical = try #require(RestoreFileFingerprint.rootComponents(path: root.path))
        let relative = url.path.dropFirst(root.path.count).split(separator: "/").map(String.init)
        return try RestoreFileFingerprint.read(components: canonical + relative)
    }
}
