import Foundation

/// CI supplies the interpreter checked for TLS 1.3 before SwiftPM changes PATH.
enum TestPythonRuntime {
    static var executable: URL {
        resolve(environment: ProcessInfo.processInfo.environment)
    }

    static func resolve(environment: [String: String]) -> URL {
        if let configured = environment["MACKOPIA_TEST_PYTHON"] {
            return URL(fileURLWithPath: configured)
        }
        let candidates = (environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("python3") }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
            ?? URL(fileURLWithPath: "/usr/bin/python3")
    }
}
