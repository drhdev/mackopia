import Darwin
import Foundation
import Testing

@testable import KopiaCLI
@testable import KopiaServer

// Each case owns real child processes; bound concurrent fixture pressure on hosted runners.
@Suite(.serialized)
struct KopiaServerProcessTests {
    private let identify = """
        import os,pathlib,signal,sys,time
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        pathlib.Path(os.environ['TMPDIR'], 'child.pid').write_text(str(os.getpid()))
        """

    @Test func handshakeDeadlineEscalatesAndReaps() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = KopiaProcessTests().request(root, script: identify + "\ntime.sleep(60)")
        let server = KopiaServerProcess(handshakeTimeout: .seconds(2), shutdownGrace: .milliseconds(20))
        await #expect(throws: KopiaServerProcessError.startFailed) {
            try await server.start(
                executable: request.executable, arguments: request.arguments, environment: request.environment)
        }
        try assertReaped(root)
    }

    @Test func cancellingStartWaitsForChildReaping() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = KopiaProcessTests().request(root, script: identify + "\ntime.sleep(60)")
        let server = KopiaServerProcess(shutdownGrace: .milliseconds(20))
        let startup = Task {
            try await server.start(
                executable: request.executable, arguments: request.arguments, environment: request.environment)
        }
        try await waitForFile(root.appendingPathComponent("child.pid"))
        startup.cancel()
        await #expect(throws: CancellationError.self) { try await startup.value }
        try assertReaped(root)
    }

    @Test func stoppingBeforeReadinessStillAllowsCleanEOFExit() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = KopiaProcessTests().request(root, script: identify + "\nsys.stdin.buffer.read()")
        let server = KopiaServerProcess(shutdownGrace: .milliseconds(100))
        let startup = Task {
            try await server.start(
                executable: request.executable, arguments: request.arguments, environment: request.environment)
        }
        try await waitForFile(root.appendingPathComponent("child.pid"))
        try await server.stop()
        await #expect(throws: KopiaServerProcessError.startFailed) { try await startup.value }
        try assertReaped(root)
    }

    @Test func invalidHandshakeStopsChildWithoutPublishingItsOutput() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = KopiaProcessTests().request(
            root,
            script: identify + """

                sys.stderr.write('SERVER PASSWORD: private-value\\nSERVER PASSWORD: duplicate\\n')
                sys.stderr.flush()
                time.sleep(60)
                """)
        let server = KopiaServerProcess(shutdownGrace: .milliseconds(20))
        let error = await #expect(throws: KopiaServerProcessError.startFailed) {
            try await server.start(
                executable: request.executable, arguments: request.arguments, environment: request.environment)
        }
        #expect(!String(reflecting: error).contains("private-value"))
        try assertReaped(root)
    }

    @Test func drainsBothPipesAfterReadinessAndStopsOnEOF() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var request = KopiaProcessTests().request(
            root,
            script: identify + """

                sys.stderr.write(os.environ['KOPIA_PASSWORD'])
                sys.stderr.flush()
                sys.stdout.buffer.write(b'o' * 1048576)
                sys.stdout.flush()
                sys.stderr.buffer.write(b'e' * 1048576)
                sys.stderr.flush()
                pathlib.Path(os.environ['TMPDIR'], 'drained').touch()
                assert sys.stdin.buffer.read() == b''
                """)
        request.environment["KOPIA_PASSWORD"] = String(
            decoding: try KopiaServerHandshakeTests().transcript(), as: UTF8.self)
        let server = KopiaServerProcess(shutdownGrace: .milliseconds(100))
        _ = try await server.start(
            executable: request.executable, arguments: request.arguments, environment: request.environment)
        do { try await waitForFile(root.appendingPathComponent("drained")) } catch {
            try? await server.stop(); throw error
        }
        try await server.stop()
        try assertReaped(root)
    }

    @Test func stopEscalatesWhenChildIgnoresEOFAndSignals() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var request = KopiaProcessTests().request(
            root,
            script: identify + """

                sys.stderr.write(os.environ['KOPIA_PASSWORD'])
                sys.stderr.flush()
                time.sleep(60)
                """)
        request.environment["KOPIA_PASSWORD"] = String(
            decoding: try KopiaServerHandshakeTests().transcript(), as: UTF8.self)
        let server = KopiaServerProcess(shutdownGrace: .milliseconds(20))
        _ = try await server.start(
            executable: request.executable, arguments: request.arguments, environment: request.environment)
        await #expect(throws: KopiaServerProcessError.stopFailed) { try await server.stop() }
        try assertReaped(root)
    }

    @Test func droppingSessionCancelsAndReapsItsChild() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var request = KopiaProcessTests().request(
            root,
            script: identify + """

                sys.stderr.write(os.environ['KOPIA_PASSWORD'])
                sys.stderr.flush()
                time.sleep(60)
                """)
        request.environment["KOPIA_PASSWORD"] = String(
            decoding: try KopiaServerHandshakeTests().transcript(), as: UTF8.self)
        var server: KopiaServerProcess? = KopiaServerProcess(shutdownGrace: .milliseconds(20))
        weak var weakServer: KopiaServerProcess?
        weakServer = server
        _ = try await server?.start(
            executable: request.executable, arguments: request.arguments, environment: request.environment)
        server = nil
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        // An already running stderr callback may retain the actor until its final executor hop completes.
        while weakServer != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let released = weakServer == nil
        #expect(released)
        let text = try String(contentsOf: root.appendingPathComponent("child.pid"), encoding: .utf8)
        let pid = try #require(Int32(text))
        while kill(pid, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try assertReaped(root)
    }

    private func waitForFile(_ file: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: file.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        guard FileManager.default.fileExists(atPath: file.path) else { throw KopiaServerProcessError.startFailed }
    }

    private func assertReaped(_ root: URL) throws {
        let text = try String(contentsOf: root.appendingPathComponent("child.pid"), encoding: .utf8)
        let pid = try #require(Int32(text))
        var status: Int32 = 0
        #expect(waitpid(pid, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
}
