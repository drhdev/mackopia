import Foundation
import Testing

@Test func agentIsEmbeddedAsLoginItem() throws {
    let agentURL = Bundle.main.bundleURL
        .appending(path: "Contents/Library/LoginItems/MacKopia Agent.app")
    let agent = try #require(Bundle(url: agentURL))
    #expect(agent.bundleIdentifier == "\(Bundle.main.bundleIdentifier ?? "").Agent")
    #expect(agent.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true)
    let executableURL = try #require(agent.executableURL)
    #expect(FileManager.default.isExecutableFile(atPath: executableURL.path))
}

@Test func kopiaAndLicenseAreBundled() throws {
    let binaryURL = Bundle.main.bundleURL.appending(path: "Contents/Helpers/kopia")
    #expect(FileManager.default.isExecutableFile(atPath: binaryURL.path))
    let resources = try #require(Bundle.main.resourceURL)
    let license = try String(contentsOf: resources.appending(path: "Kopia/LICENSE"), encoding: .utf8)
    #expect(license.contains("Apache License"))
    #expect(license.contains("Version 2.0"))
    let readme = try String(contentsOf: resources.appending(path: "Kopia/README.md"), encoding: .utf8)
    #expect(readme.contains("Kopia is licensed under the Apache License"))
}

@Test func launchAgentMatchesEmbeddedExecutable() throws {
    let appID = try #require(Bundle.main.bundleIdentifier)
    let plist = Bundle.main.bundleURL.appending(path: "Contents/Library/LaunchAgents/\(appID).Agent.plist")
    let contents = try Data(contentsOf: plist)
    let job = try #require(PropertyListSerialization.propertyList(from: contents, format: nil) as? [String: Any])
    #expect(job["Label"] as? String == appID + ".Agent")
    #expect(job["MachServices"] as? [String: Bool] == [appID + ".Agent.xpc": true])
    #expect(job["AssociatedBundleIdentifiers"] as? [String] == [appID])
    #expect(job["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false])
    #expect(job["ProcessType"] as? String == "Standard")
    #expect(job["LimitLoadToSessionType"] as? String == "Aqua")
    let program = try #require(job["BundleProgram"] as? String)
    #expect(!program.hasPrefix("/"))
    #expect(FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appending(path: program).path))
}
