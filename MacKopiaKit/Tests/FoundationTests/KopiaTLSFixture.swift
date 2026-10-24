import Darwin
import Foundation
import Testing

@testable import KopiaCLI
@testable import KopiaServer

/// Owns a disposable TLS process; no key, credential or response is written to disk.
final class KopiaTLSFixture {
    let root: URL
    let client: KopiaServerClient
    private let child: KopiaChildProcess

    init(mode: String) async throws {
        root = try KopiaProcessTests().temporaryRoot()
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
                "Scripts/native_tls_fixture.py")
        do {
            child = try KopiaChildProcess.launch(
                KopiaProcessRequest(
                    executable: TestPythonRuntime.executable, arguments: [script.path, mode, root.path],
                    environment: [
                        "HOME": root.path, "TMPDIR": root.path, "LANG": "en_US.UTF-8",
                        "PYTHONDONTWRITEBYTECODE": "1",
                    ]), configuration: nil, keepInputOpen: true)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        do {
            var parser = KopiaServerHandshakeParser()
            var handshake: KopiaServerHandshake?
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            var buffer = [UInt8](repeating: 0, count: 8192)
            while handshake == nil, ContinuousClock.now < deadline {
                try Task.checkCancellation()
                let count = Darwin.read(child.output, &buffer, buffer.count)
                if count > 0 { handshake = try parser.consume(Data(buffer.prefix(count))) }
                if count == 0 { break }
                if count < 0, errno != EAGAIN, errno != EINTR { throw FixtureError.startFailed }
                // Drain diagnostics without retaining or publishing potentially sensitive output.
                while Darwin.read(child.error, &buffer, buffer.count) > 0 {}
                if handshake == nil { try await Task.sleep(for: .milliseconds(10)) }
            }
            guard let handshake else { throw FixtureError.startFailed }
            client = KopiaServerClient(handshake: handshake)
        } catch {
            Self.stop(child)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    deinit {
        Self.stop(child)
        try? FileManager.default.removeItem(at: root)
    }

    private static func stop(_ child: KopiaChildProcess) {
        // Foundation Process termination/run-loop waits can stall cooperative executor threads.
        // Own this fixture's waitpid directly; the unreaped PID cannot be reused before signaling.
        child.signal(SIGKILL)
        var status: Int32 = 0
        while waitpid(child.pid, &status, 0) < 0, errno == EINTR {}
        if let input = child.input { Darwin.close(input) }
        Darwin.close(child.output)
        Darwin.close(child.error)
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
