import Foundation
import LightweightCodeRequirements
import Security

/// The installed, sealed bundle is the trust anchor; no Apple account or publisher certificate is required.
enum AgentSigningIdentity {
    enum Role { case app, agent }

    static func requireSignature(signingIdentifier: String) throws {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
        else { throw AgentServiceError.signingRequired }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw AgentServiceError.signingRequired
        }
        _ = try signature(staticCode, signingIdentifier: signingIdentifier)
    }

    static func peerRequirement(identity: AgentServiceIdentity, role: Role) throws -> ProcessCodeRequirement {
        let ownID = role == .app ? identity.appBundleID : identity.agentBundleID
        try requireSignature(signingIdentifier: ownID)
        let urls = try bundleURLs(current: Bundle.main.bundleURL, identity: identity, role: role)
        // Validate the outer seal too: it covers the embedded helper whose hash is trusted below.
        _ = try requirement(codeURL: urls.app, signingIdentifier: identity.appBundleID)
        try requireRunningMatch(codeURL: role == .app ? urls.app : urls.agent, signingIdentifier: ownID)
        return try requirement(
            codeURL: role == .app ? urls.agent : urls.app,
            signingIdentifier: role == .app ? identity.agentBundleID : identity.appBundleID)
    }

    static func requireRunningMatch(codeURL: URL, signingIdentifier: String) throws {
        let hash = try validatedHash(codeURL: codeURL, signingIdentifier: signingIdentifier)
        // Compare the running code with the disk seal using Security's dynamic code validator.
        // Only hexadecimal hash bytes enter the requirement, never a configurable expression.
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        var ownRequirement: SecRequirement?
        var running: SecCode?
        guard
            SecRequirementCreateWithString(("cdhash H\"" + hex + "\"") as CFString, [], &ownRequirement)
                == errSecSuccess,
            let ownRequirement, SecCodeCopySelf([], &running) == errSecSuccess, let running,
            SecCodeCheckValidity(running, SecCSFlags(rawValue: kSecCSStrictValidate), ownRequirement) == errSecSuccess
        else { throw AgentServiceError.signingRequired }
    }

    static func bundleURLs(
        current: URL, identity: AgentServiceIdentity, role: Role
    ) throws -> (app: URL, agent: URL) {
        let current = current.standardizedFileURL.resolvingSymlinksInPath()
        let app =
            role == .app
            ? current
            : current.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
        let agent = app.appending(path: "Contents/Library/LoginItems/MacKopia Agent.app")
        guard app.pathExtension == "app", role == .app || agent.path == current.path,
            Bundle(url: app)?.bundleIdentifier == identity.appBundleID,
            Bundle(url: agent)?.bundleIdentifier == identity.agentBundleID
        else { throw AgentServiceError.signingRequired }
        return (app, agent)
    }

    static func requirement(codeURL: URL, signingIdentifier: String) throws -> ProcessCodeRequirement {
        let hash = try validatedHash(codeURL: codeURL, signingIdentifier: signingIdentifier)
        do {
            return try ProcessCodeRequirement.allOf {
                SigningIdentifier(signingIdentifier)
                CodeDirectoryHash(hash)
            }
        } catch { throw AgentServiceError.signingRequired }
    }

    private static func validatedHash(codeURL: URL, signingIdentifier: String) throws -> Data {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(codeURL as CFURL, [], &code) == errSecSuccess, let code,
            SecStaticCodeCheckValidity(
                code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess
        else { throw AgentServiceError.signingRequired }
        return try signature(code, signingIdentifier: signingIdentifier)
    }

    private static func signature(_ code: SecStaticCode, signingIdentifier: String) throws -> Data {
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let values = information as? [String: Any],
            values[kSecCodeInfoIdentifier as String] as? String == signingIdentifier,
            let hash = values[kSecCodeInfoUnique as String] as? Data, hash.count == 20
        else { throw AgentServiceError.signingRequired }
        return hash
    }
}
