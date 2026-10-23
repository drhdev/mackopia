import CryptoKit
import Foundation
import Security

/// Trust is restricted to the owned child's certificate and IPv4 loopback endpoint.
final class KopiaServerTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let certificateDER: Data
    private let fingerprint: Data
    private let port: Int

    init(handshake: KopiaServerHandshake) {
        certificateDER = handshake.certificateDER
        fingerprint = handshake.fingerprint
        port = handshake.address.port ?? 0
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            space.host == "127.0.0.1", space.port == port, space.protocol == "https",
            let trust = space.serverTrust, accepts(trust)
        else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Even a redirect on the same origin must not carry credentials or bypass typed routes.
        completionHandler(nil)
    }

    func accepts(_ trust: SecTrust) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
            Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)) == fingerprint,
            let anchor = SecCertificateCreateWithData(nil, certificateDER as CFData),
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "127.0.0.1" as CFString)) == errSecSuccess,
            SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
            SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
            SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess
        else { return false }
        // Pinning alone does not establish certificate validity or hostname identity.
        return SecTrustEvaluateWithError(trust, nil)
    }
}
