import Foundation

/// Internal execution boundary; only Agent-side typed commands may construct production requests.
/// stdout/stderr are untrusted private data, never log or forward them to the UI without redaction.
struct KopiaProcessRequest: Sendable, CustomReflectable {
    let executable: URL
    let arguments: [String]
    var environment: [String: String]
    var timeout: Duration = .seconds(120)
    var outputLimit: Int = 4 * 1024 * 1024
    var webDAVConfiguration: Data?
    var repositoryDirectory: URL?

    var customMirror: Mirror { Mirror(self, children: ["request": "<private>"]) }
}
