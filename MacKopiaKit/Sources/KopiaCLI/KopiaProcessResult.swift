import Foundation

struct KopiaProcessResult: Sendable, CustomReflectable {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data

    var customMirror: Mirror { Mirror(self, children: ["result": "<private>"]) }
}
