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
        process.executableURL = TestPythonRuntime.executable
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
                Self.stop(process)
            }
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    deinit {
        try? input.fileHandleForWriting.close()
        Self.stop(process)
        try? FileManager.default.removeItem(at: root)
    }

    private static func stop(_ process: Process) {
        // waitUntilExit can strand its caller's run loop after termination on a cooperative executor.
        // Foundation owns waitpid; observe its reaped state without entering that run loop.
        if process.isRunning { process.terminate() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while process.isRunning {
            if ContinuousClock.now >= deadline { kill(process.processIdentifier, SIGKILL) }
            usleep(1_000)
        }
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
