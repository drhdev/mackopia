import Foundation

/// Backend credentials are supplied only to owned children; never part of their argument arrays.
package struct KopiaS3Authentication: Sendable, CustomReflectable {
    let accessKey: String
    let secretKey: String
    let sessionToken: String

    package init(accessKey: String, secretKey: String, sessionToken: String = "") throws {
        guard !accessKey.isEmpty, !secretKey.isEmpty,
            [accessKey, secretKey, sessionToken].allSatisfy({ !$0.utf8.contains(0) && $0.utf8.count <= 16_384 })
        else { throw KopiaProcessError.invalidRequest }
        self.accessKey = accessKey; self.secretKey = secretKey; self.sessionToken = sessionToken
    }

    package var environment: [String: String] {
        ["AWS_ACCESS_KEY_ID": accessKey, "AWS_SECRET_ACCESS_KEY": secretKey, "AWS_SESSION_TOKEN": sessionToken]
    }
    package var customMirror: Mirror { Mirror(self, children: [:]) }
}
