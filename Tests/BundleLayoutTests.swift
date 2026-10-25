import Foundation
import MachO
import Security
import Testing

@Test func agentIsEmbeddedAsLoginItem() throws {
    let agentURL = try builtApp().bundleURL
        .appending(path: "Contents/Library/LoginItems/MacKopia Agent.app")
    let agent = try #require(Bundle(url: agentURL))
    #expect(agent.bundleIdentifier == "\(try builtApp().bundleIdentifier ?? "").Agent")
    #expect(agent.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true)
    let executableURL = try #require(agent.executableURL)
    #expect(FileManager.default.isExecutableFile(atPath: executableURL.path))
}

@Test func kopiaAndLicenseAreBundled() throws {
    let binaryURL = try builtApp().bundleURL.appending(path: "Contents/Helpers/kopia")
    #expect(FileManager.default.isExecutableFile(atPath: binaryURL.path))
    let resources = try #require(try builtApp().resourceURL)
    let license = try String(contentsOf: resources.appending(path: "Kopia/LICENSE"), encoding: .utf8)
    #expect(license.contains("Apache License"))
    #expect(license.contains("Version 2.0"))
    let readme = try String(contentsOf: resources.appending(path: "Kopia/README.md"), encoding: .utf8)
    #expect(readme.contains("Kopia is licensed under the Apache License"))
}

@Test func launchAgentMatchesEmbeddedExecutable() throws {
    let appID = try #require(try builtApp().bundleIdentifier)
    let plist = try builtApp().bundleURL.appending(path: "Contents/Library/LaunchAgents/\(appID).Agent.plist")
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
    #expect(FileManager.default.isExecutableFile(atPath: try builtApp().bundleURL.appending(path: program).path))
}

@Test func accountlessProductSignaturesRetainHardenedRuntime() throws {
    let app = try builtApp()
    let appID = try #require(app.bundleIdentifier)
    #expect(app.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String == "27.0")
    #expect(app.executableArchitectures == [NSNumber(value: CPU_TYPE_ARM64)])
    let agent = try #require(
        Bundle(url: app.bundleURL.appending(path: "Contents/Library/LoginItems/MacKopia Agent.app")))
    #expect(agent.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String == "27.0")
    #expect(agent.executableArchitectures == [NSNumber(value: CPU_TYPE_ARM64)])
    for (url, identifier) in [
        (app.bundleURL, appID),
        (app.bundleURL.appending(path: "Contents/Library/LoginItems/MacKopia Agent.app"), appID + ".Agent"),
        (app.bundleURL.appending(path: "Contents/Helpers/kopia"), "kopia"),
    ] {
        var code: SecStaticCode?
        try #require(SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess)
        let signed = try #require(code)
        #expect(
            SecStaticCodeCheckValidity(
                signed, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess)
        var information: CFDictionary?
        try #require(
            SecCodeCopySigningInformation(signed, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess)
        let values = try #require(information as? [String: Any])
        #expect(values[kSecCodeInfoTeamIdentifier as String] == nil)
        if identifier != "kopia" { #expect(values[kSecCodeInfoIdentifier as String] as? String == identifier) }
        let flags = try #require(values[kSecCodeInfoFlags as String] as? UInt32)
        #expect(flags & 0x10000 != 0)  // CS_RUNTIME, including the embedded engine.
    }
}

private final class BundleMarker: NSObject {}

/// Artifact checks run outside the product: loading an ad-hoc XCTest bundle would violate its library validation.
private func builtApp() throws -> Bundle {
    let products = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()
    return try #require(Bundle(url: products.appending(path: "MacKopia.app")))
}
