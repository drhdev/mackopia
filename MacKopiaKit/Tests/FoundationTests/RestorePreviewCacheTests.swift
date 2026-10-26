import BackupDomain
import Foundation
import Testing

@testable import BackupEngine

@Suite("Abandoned restore previews")
struct RestorePreviewCacheTests {
    @Test func cleansPrivateSessionsWithoutFollowingLinks() throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try RestorePreviewCache.prepare(home: home)
        let session = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: session, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try Data("restored private content".utf8).write(to: session.appendingPathComponent("preview"))
        let outside = home.appendingPathComponent("retained")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: session.appendingPathComponent("link"), withDestinationURL: outside)
        let unknown = root.appendingPathComponent("unrecognized")
        try Data("keep".utf8).write(to: unknown)
        let link = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home)
        try RestorePreviewCache.removeAbandonedSessions(home: home)
        #expect(!FileManager.default.fileExists(atPath: session.path))
        #expect(try Data(contentsOf: outside) == Data("keep".utf8))
        #expect(FileManager.default.fileExists(atPath: unknown.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == home.path)
        try RestorePreviewCache.removeAbandonedSessions(home: home)
    }

    @Test func rejectsRedirectedOrNonprivateRoot() throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try RestorePreviewCache.prepare(home: home)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        #expect(throws: LocalServiceIssue.destination) { try RestorePreviewCache.removeAbandonedSessions(home: home) }
        try FileManager.default.removeItem(at: root)
        let outside = home.appendingPathComponent("retained")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        #expect(throws: LocalServiceIssue.destination) { try RestorePreviewCache.removeAbandonedSessions(home: home) }
        #expect(throws: LocalServiceIssue.destination) { try RestorePreviewCache.prepare(home: home) }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func absentCacheDoesNotCreateDirectories() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try RestorePreviewCache.removeAbandonedSessions(home: home)
        #expect(!FileManager.default.fileExists(atPath: home.path))
    }
}
