import Foundation

struct KopiaTasks: Decodable, Sendable, CustomReflectable {
    let tasks: [KopiaTask]?

    var customMirror: Mirror { Mirror(self, children: ["tasks": "<private>"]) }
}
