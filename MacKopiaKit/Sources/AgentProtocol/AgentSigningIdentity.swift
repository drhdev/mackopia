import Foundation
import Security

/// Read the running process's verified signature, never a configurable team-ID string.
enum AgentSigningIdentity {
    static func requireTeamSignature(signingIdentifier: String) throws {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
        else { throw AgentServiceError.signingRequired }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw AgentServiceError.signingRequired
        }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let values = information as? [String: Any],
            values[kSecCodeInfoIdentifier as String] as? String == signingIdentifier,
            let team = values[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty,
            let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate], !certificates.isEmpty
        else { throw AgentServiceError.signingRequired }
    }
}
