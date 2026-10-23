import CryptoKit
import Foundation
import Security

/// Values from the owned child's stderr; never forward them to diagnostics or XPC.
struct KopiaServerHandshake: Sendable, CustomReflectable {
    let address: URL
    let certificateDER: Data
    let fingerprint: Data
    let password: String
    let controlPassword: String

    var customMirror: Mirror { Mirror(self, children: [:]) }

    init(fields: [String: String]) throws {
        guard let addressText = fields["SERVER ADDRESS"],
            let address = URL(string: addressText), let port = address.port,
            (1...65535).contains(port), addressText == "https://127.0.0.1:\(port)",
            let pin = fields["SERVER CERT SHA256"], pin.utf8.count == 64,
            pin.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
            let encoded = fields["SERVER CERTIFICATE"], let pemData = Data(base64Encoded: encoded),
            let pem = String(data: pemData, encoding: .ascii),
            let password = fields["SERVER PASSWORD"], Self.validPassword(password),
            let controlPassword = fields["SERVER CONTROL PASSWORD"], Self.validPassword(controlPassword)
        else { throw KopiaServerHandshakeError.invalid }

        let lines = pem.split(separator: "\n", omittingEmptySubsequences: false)
        let bodyLines = lines.last == "" ? lines.dropLast() : lines[...]
        guard bodyLines.first == "-----BEGIN CERTIFICATE-----",
            bodyLines.last == "-----END CERTIFICATE-----",
            let der = Data(base64Encoded: bodyLines.dropFirst().dropLast().joined()),
            SecCertificateCreateWithData(nil, der as CFData) != nil
        else { throw KopiaServerHandshakeError.invalid }
        let digest = Data(SHA256.hash(data: der))
        guard digest.map({ String(format: "%02x", $0) }).joined() == pin.lowercased()
        else { throw KopiaServerHandshakeError.invalid }

        self.address = address
        self.certificateDER = der
        self.fingerprint = digest
        self.password = password
        self.controlPassword = controlPassword
    }

    private static func validPassword(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && value.utf8.allSatisfy { (33...126).contains($0) }
    }
}
