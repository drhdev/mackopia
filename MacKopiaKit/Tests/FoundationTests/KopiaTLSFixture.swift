import Darwin
import Foundation
import Testing

@testable import KopiaServer

/// Owns a disposable TLS process; no key, credential or response is written to disk.
final class KopiaTLSFixture {
    let root: URL
    let client: KopiaServerClient
    private let process: Process
    private let input: Pipe

    init(mode: String) async throws {
        root = try KopiaProcessTests().temporaryRoot()
        process = Process()
        input = Pipe()
        let output = Pipe()
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
                "Scripts/native_tls_fixture.py")
        // Xcode's /usr/bin/python3 uses LibreSSL without TLS 1.3. Use the existing test runtime from PATH.
        let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: String($0)).appendingPathComponent("python3") }
        guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            try? FileManager.default.removeItem(at: root)
            throw FixtureError.startFailed
        }
        process.executableURL = python
        process.arguments = [script.path, mode, root.path]
        process.environment = [
            "HOME": root.path, "TMPDIR": root.path, "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1",
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var launched = false
        do {
            try process.run()
            launched = true
            let descriptor = output.fileHandleForReading.fileDescriptor
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw FixtureError.startFailed }
            var parser = KopiaServerHandshakeParser()
            var handshake: KopiaServerHandshake?
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            var buffer = [UInt8](repeating: 0, count: 8192)
            while handshake == nil, ContinuousClock.now < deadline, process.isRunning {
                try Task.checkCancellation()
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 { handshake = try parser.consume(Data(buffer.prefix(count))) }
                if count == 0 { break }
                if count < 0, errno != EAGAIN, errno != EINTR { throw FixtureError.startFailed }
                if handshake == nil { try await Task.sleep(for: .milliseconds(10)) }
            }
            guard let handshake else { throw FixtureError.startFailed }
            client = KopiaServerClient(handshake: handshake)
        } catch {
            try? input.fileHandleForWriting.close()
            if launched {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    deinit {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: root)
    }

    func waitFor(_ name: String, timeout: Duration = .seconds(3)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !exists(name), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(exists(name))
        guard exists(name) else { throw FixtureError.missingEvent }
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    enum FixtureError: Error { case startFailed, missingEvent }
}
