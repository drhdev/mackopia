import CryptoKit
import Foundation
import Testing

@testable import KopiaServer

struct KopiaServerHandshakeTests {
    // Public, disposable test certificate. Its private key was discarded at generation.
    private let pem = """
        -----BEGIN CERTIFICATE-----
        MIIDCTCCAfGgAwIBAgIUUX9QZK2GE6yqC+6Se11DG6Eqd7wwDQYJKoZIhvcNAQEL
        BQAwFDESMBAGA1UEAwwJMTI3LjAuMC4xMB4XDTI2MTAyMzIwMjMwMFoXDTI2MTAy
        NDIwMjMwMFowFDESMBAGA1UEAwwJMTI3LjAuMC4xMIIBIjANBgkqhkiG9w0BAQEF
        AAOCAQ8AMIIBCgKCAQEAn63K0brWCMUVSiYMSWCjD2Ehjm2JZXz4VqtFxdl1BaOw
        IBR2C3/wvGWUw6VoPzp/Pm3JvsO3GS4NRHqJQxfjaPh+n8ww0fWPqurjjkV0Adjv
        4gidI5YgGeDUwP/M4Rj3eOYJP4An40QoxN+BFmFc0R+RkVP8SgMLnHxVH0FUw7vL
        FlHMwEz9grK5ky9vysJmbzzR3+li/nEYDGwB5XJzZmYONkwOgtdFQ6XQzg6CBh1D
        6O/DiLa4jWOqvsofwNF/WUJ9fddym/pXk0/4k7lt1xz5FYfWyLZLGbW/ZFQYT9EM
        jlOH4dS9eKOet8N2eXr/JPa8zsgZax/WNF0aazzxjQIDAQABo1MwUTAdBgNVHQ4E
        FgQUM4GyGMBCgxgnDYZ43RZq7mM+mocwHwYDVR0jBBgwFoAUM4GyGMBCgxgnDYZ4
        3RZq7mM+mocwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAaYgT
        M+Cy2WaiC3CJWK6Vswcog5P2Wk/1VQEquScWkS6EofTcsmIShd24qrUjyE7PJRQe
        ypOWhKI8lxhaPd8OT2s7Iaqql3dZcLbEtipomCvQuQEEWghT60Nx6mwl96NviigP
        +j85BrAoFrTRZUaS1/YasmGJhmXUHg9LQX35sailKFzU/+E5W0QvBaDjwMY151lT
        Slup3ha8Ly8kMnnFp4Virph+EAThevlM38nm0YrC5MfROXvZ6dQHglBLzSF/ABfp
        ZCb87eTm2ddxO/X5euJD3mqJf6AehspopxHlOKHUIrIHTiXCRIG76azzqpPWX8x4
        rBiwxnc0A/HcTEeycg==
        -----END CERTIFICATE-----
        """ + "\n"

    func transcript(address: String = "https://127.0.0.1:12345", pin: String? = nil) throws -> Data {
        let body = pem.split(separator: "\n").dropFirst().dropLast().joined()
        let der = try #require(Data(base64Encoded: body))
        let digest = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        return Data(
            ([
                "SERVER PASSWORD: ephemeral-api-value",
                "SERVER ADDRESS: " + address,
                "SERVER CERT SHA256: " + (pin ?? digest),
                "NOTIFICATION: discarded child output",
                "SERVER CERTIFICATE: " + Data(pem.utf8).base64EncodedString(),
                "SERVER CONTROL PASSWORD: ephemeral-control-value",
            ].joined(separator: "\n") + "\n").utf8)
    }

    @Test func acceptsArbitraryChunksAndRedactsReflection() throws {
        let data = try transcript()
        for chunkSize in [1, 7, data.count] {
            var parser = KopiaServerHandshakeParser()
            var result: KopiaServerHandshake?
            for start in stride(from: 0, to: data.count, by: chunkSize) {
                result = try parser.consume(data.subdata(in: start..<min(start + chunkSize, data.count))) ?? result
            }
            let handshake = try #require(result)
            #expect(handshake.address.absoluteString == "https://127.0.0.1:12345")
            #expect(handshake.password == "ephemeral-api-value")
            #expect(handshake.controlPassword == "ephemeral-control-value")
            #expect(handshake.fingerprint.count == 32)
            #expect(!String(reflecting: handshake).contains("ephemeral"))
            #expect(!String(reflecting: parser).contains("ephemeral"))
            try parser.finish()
        }
    }

    @Test func rejectsNoncanonicalOrNonLoopbackAddresses() throws {
        for address in [
            "http://127.0.0.1:12345", "https://localhost:12345", "https://127.0.0.1:0",
            "https://127.0.0.1:65536", "https://127.0.0.1:012345", "https://127.0.0.1:12345/",
            "https://user@127.0.0.1:12345", "https://127.0.0.1:12345?x=1", "https://[::1]:12345",
        ] {
            var parser = KopiaServerHandshakeParser()
            let data = try transcript(address: address)
            #expect(throws: KopiaServerHandshakeError.invalid) { try parser.consume(data) }
        }
    }

    @Test func rejectsWrongPinAndInvalidCertificate() throws {
        for pin in [String(repeating: "0", count: 64), "invalid", String(repeating: "g", count: 64)] {
            var parser = KopiaServerHandshakeParser()
            let data = try transcript(pin: pin)
            #expect(throws: KopiaServerHandshakeError.invalid) { try parser.consume(data) }
        }
        var parser = KopiaServerHandshakeParser()
        let data = try transcript()
        let text = try #require(String(data: data, encoding: .utf8))
        let invalid = text.replacingOccurrences(of: Data(pem.utf8).base64EncodedString(), with: "YWJj")
        #expect(throws: KopiaServerHandshakeError.invalid) { try parser.consume(Data(invalid.utf8)) }
    }

    @Test func rejectsDuplicatesMalformedFieldsAndKeepsFailureTerminal() throws {
        for line in [
            "SERVER PASSWORD: second", "SERVER PASSWORD:", "SERVER PASSWORD: ",
            "SERVER ADDRESS: https://127.0.0.1:12345\r", "SERVER PASSWORD: nul\0",
        ] {
            var parser = KopiaServerHandshakeParser()
            _ = try parser.consume(Data("SERVER PASSWORD: ephemeral-api-value\n".utf8))
            #expect(throws: KopiaServerHandshakeError.invalid) { try parser.consume(Data((line + "\n").utf8)) }
            #expect(throws: KopiaServerHandshakeError.invalid) { try parser.consume(Data()) }
            #expect(!String(reflecting: parser).contains("ephemeral"))
        }
    }

    @Test func requiresCompleteTerminatedFieldsAndBoundsAllInput() throws {
        var incomplete = KopiaServerHandshakeParser()
        _ = try incomplete.consume(Data("SERVER PASSWORD: ephemeral-api-value".utf8))
        #expect(throws: KopiaServerHandshakeError.incomplete) { try incomplete.finish() }
        #expect(throws: KopiaServerHandshakeError.incomplete) { try incomplete.consume(Data()) }
        var longLine = KopiaServerHandshakeParser()
        #expect(throws: KopiaServerHandshakeError.limitExceeded) {
            try longLine.consume(Data(repeating: 65, count: 32_769))
        }
        var total = KopiaServerHandshakeParser()
        for _ in 0..<8 { _ = try total.consume(Data(repeating: 10, count: 32_768)) }
        #expect(throws: KopiaServerHandshakeError.limitExceeded) { try total.consume(Data([10])) }
        var invalidUTF8 = KopiaServerHandshakeParser()
        #expect(throws: KopiaServerHandshakeError.invalid) { try invalidUTF8.consume(Data([255, 10])) }
    }
}
