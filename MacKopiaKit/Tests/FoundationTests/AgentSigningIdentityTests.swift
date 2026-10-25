import Foundation
import LightweightCodeRequirements
import Security
import Testing

@testable import AgentProtocol

struct AgentSigningIdentityTests {
    @Test func adHocBundleRequiresExactCodeHashAndIdentifierWithoutTeam() throws {
        let fixture = try SignedAgentFixture()
        defer { fixture.remove() }
        let requirement = try AgentSigningIdentity.requirement(
            codeURL: fixture.agent, signingIdentifier: fixture.identity.agentBundleID)
        #expect(try matches(requirement, at: fixture.agent))
        // Same signing identifier, different executable: name-only spoofing must fail.
        let other = try fixture.makeApp(
            name: "Other", identifier: fixture.identity.agentBundleID, executable: "/usr/bin/true")
        #expect(try !matches(requirement, at: other))
        #expect(throws: AgentServiceError.signingRequired) {
            try AgentSigningIdentity.requirement(
                codeURL: fixture.agent, signingIdentifier: fixture.identity.appBundleID)
        }
        var code: SecStaticCode?
        #expect(SecStaticCodeCreateWithPath(fixture.agent as CFURL, [], &code) == errSecSuccess)
        var information: CFDictionary?
        #expect(
            SecCodeCopySigningInformation(
                try #require(code), SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess)
        let values = try #require(information as? [String: Any])
        #expect(values[kSecCodeInfoTeamIdentifier as String] == nil)
    }

    @Test func alteredOuterSealAndUnsignedCodeAreRejected() throws {
        let fixture = try SignedAgentFixture()
        defer { fixture.remove() }
        _ = try AgentSigningIdentity.requirement(codeURL: fixture.app, signingIdentifier: fixture.identity.appBundleID)
        try Data("changed".utf8).write(to: fixture.app.appending(path: "Contents/Resources/marker"))
        #expect(throws: AgentServiceError.signingRequired) {
            try AgentSigningIdentity.requirement(codeURL: fixture.app, signingIdentifier: fixture.identity.appBundleID)
        }
        let unsigned = fixture.root.appending(path: "unsigned")
        try Data("no executable signature".utf8).write(to: unsigned)
        #expect(throws: AgentServiceError.signingRequired) {
            try AgentSigningIdentity.requirement(codeURL: unsigned, signingIdentifier: fixture.identity.appBundleID)
        }
    }

    @Test func bundleLayoutResolvesBothRolesAndRejectsOtherLocations() throws {
        let fixture = try SignedAgentFixture()
        defer { fixture.remove() }
        let app = try AgentSigningIdentity.bundleURLs(current: fixture.app, identity: fixture.identity, role: .app)
        let agent = try AgentSigningIdentity.bundleURLs(
            current: fixture.agent, identity: fixture.identity, role: .agent)
        #expect(app.app.path == agent.app.path && app.agent.path == agent.agent.path)
        #expect(app.app.path == fixture.app.path && app.agent.path == fixture.agent.path)
        #expect(throws: AgentServiceError.signingRequired) {
            try AgentSigningIdentity.bundleURLs(current: fixture.agent, identity: fixture.identity, role: .app)
        }
        #expect(throws: AgentServiceError.signingRequired) {
            try AgentSigningIdentity.bundleURLs(current: fixture.app, identity: fixture.identity, role: .agent)
        }
        let wrong = try AgentServiceIdentity(appBundleID: "invalid.other.App")
        #expect(throws: AgentServiceError.signingRequired) {
            try AgentSigningIdentity.bundleURLs(current: fixture.app, identity: wrong, role: .app)
        }
    }

    @Test func runningCodeMatchesOnlyItsOwnSealedExecutable() throws {
        var running: SecCode?
        try #require(SecCodeCopySelf([], &running) == errSecSuccess)
        var code: SecStaticCode?
        try #require(SecCodeCopyStaticCode(try #require(running), [], &code) == errSecSuccess)
        let own = try #require(code)
        var information: CFDictionary?
        try #require(
            SecCodeCopySigningInformation(own, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess)
        let values = try #require(information as? [String: Any])
        let identifier = try #require(values[kSecCodeInfoIdentifier as String] as? String)
        var path: CFURL?
        try #require(SecCodeCopyPath(own, [], &path) == errSecSuccess)
        try AgentSigningIdentity.requireSignature(signingIdentifier: identifier)
        try AgentSigningIdentity.requireRunningMatch(codeURL: #require(path) as URL, signingIdentifier: identifier)
        let fixture = try SignedAgentFixture()
        defer { fixture.remove() }
        #expect(throws: AgentServiceError.signingRequired) {
            try AgentSigningIdentity.requireRunningMatch(
                codeURL: fixture.app, signingIdentifier: fixture.identity.appBundleID)
        }
    }

    private func matches(_ requirement: ProcessCodeRequirement, at url: URL) throws -> Bool {
        var code: SecStaticCode?
        #expect(SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess)
        let result = SecStaticCodeCheckValidityWithOnDiskRequirement(
            code: try #require(code), flags: [], requirement: try OnDiskCodeRequirement(requirement))
        return result.signatureIsValid && result.requirementMatched
    }
}

/// Disposable bundles signed with '-' only; no keychain identity, registration or user app is touched.
private struct SignedAgentFixture {
    let root: URL
    let identity: AgentServiceIdentity
    var app: URL { root.appending(path: "MacKopia.app") }
    var agent: URL { app.appending(path: "Contents/Library/LoginItems/MacKopia Agent.app") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "mackopia-signing-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        identity = try AgentServiceIdentity(appBundleID: "test.accountless.MacKopia")
        do {
            try populate(app, identifier: identity.appBundleID, executable: "/usr/bin/true")
            try populate(agent, identifier: identity.agentBundleID, executable: "/bin/echo")
            try sign(agent)
            try sign(app)
        } catch { remove(); throw error }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func makeApp(name: String, identifier: String, executable: String) throws -> URL {
        let url = root.appending(path: name + ".app")
        try populate(url, identifier: identifier, executable: executable)
        try sign(url)
        return url
    }

    private func populate(_ url: URL, identifier: String, executable: String) throws {
        try FileManager.default.createDirectory(
            at: url.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: url.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: executable, toPath: url.appending(path: "Contents/MacOS/Fixture").path)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": identifier, "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL",
            ], format: .xml, options: 0)
        try plist.write(to: url.appending(path: "Contents/Info.plist"))
        try Data("original".utf8).write(to: url.appending(path: "Contents/Resources/marker"))
    }

    private func sign(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--options", "runtime", "--timestamp=none", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }
}
