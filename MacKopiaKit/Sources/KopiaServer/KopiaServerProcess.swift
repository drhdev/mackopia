import Foundation
import KopiaCLI

/// Single-use server session. No caller receives a PID or raw child diagnostics.
actor KopiaServerProcess {
    private let transport: KopiaServerTransport
    private let clock: any Clock<Duration>
    private let handshakeTimeout: Duration
    private var parser = KopiaServerHandshakeParser()
    private var handshake: KopiaServerHandshake?
    private var lifecycle: Task<Int32, any Error>?
    private var finished = false
    private var stopping = false

    var isRunning: Bool { lifecycle != nil && !finished }

    init(
        clock: any Clock<Duration> = ContinuousClock(), handshakeTimeout: Duration = .seconds(30),
        shutdownGrace: Duration = .seconds(10)
    ) {
        self.clock = clock
        self.handshakeTimeout = handshakeTimeout
        transport = KopiaServerTransport(clock: clock, grace: shutdownGrace)
    }

    func start(configuration: KopiaServerConfiguration) async throws -> KopiaServerHandshake {
        try await start(
            executable: configuration.executable, arguments: configuration.arguments,
            environment: configuration.environment, webDAVConfiguration: configuration.webDAVConfiguration,
            repositoryDirectory: configuration.repositoryDirectory)
    }

    /// Low-level seam for process lifecycle tests; production callers use the typed configuration.
    func start(
        executable: URL, arguments: [String], environment: [String: String],
        webDAVConfiguration: Data? = nil, repositoryDirectory: URL? = nil
    ) async throws -> KopiaServerHandshake {
        guard lifecycle == nil, !stopping, handshakeTimeout > .zero else { throw KopiaServerProcessError.startFailed }
        try Task.checkCancellation()
        let transport = self.transport
        let receive: @Sendable (Data) async throws -> Void = { [weak self] data in
            guard let self else { throw CancellationError() }
            try await self.receive(data)
        }
        let lifecycle = Task {
            try await transport.run(
                executable: executable, arguments: arguments, environment: environment,
                webDAVConfiguration: webDAVConfiguration, repositoryDirectory: repositoryDirectory,
                standardError: receive)
        }
        self.lifecycle = lifecycle
        Task { [weak self] in
            _ = await lifecycle.result
            await self?.didFinish()
        }
        let clock = self.clock
        do {
            return try await awaitHandshake(clock: clock)
        } catch {
            if !stopping { await transport.cancel() }
            _ = await lifecycle.result
            handshake = nil
            parser = KopiaServerHandshakeParser()
            if error is CancellationError { throw CancellationError() }
            throw KopiaServerProcessError.startFailed
        }
    }

    deinit {
        let transport = transport
        Task { await transport.cancel() }
    }

    private func didFinish() {
        finished = true
        handshake = nil
        parser = KopiaServerHandshakeParser()
    }

    func stop() async throws {
        stopping = true
        await transport.shutdown()
        guard let lifecycle else { return }
        let result = await lifecycle.result
        handshake = nil
        parser = KopiaServerHandshakeParser()
        guard case .success(0) = result else { throw KopiaServerProcessError.stopFailed }
    }

    private func awaitHandshake<C: Clock>(clock: C) async throws -> KopiaServerHandshake where C.Duration == Duration {
        let deadline = clock.now.advanced(by: handshakeTimeout)
        while true {
            try Task.checkCancellation()
            guard !finished, !stopping, clock.now < deadline else { throw KopiaServerProcessError.startFailed }
            if let handshake { return handshake }
            try await clock.sleep(for: .milliseconds(10))
        }
    }

    private func receive(_ data: Data) throws {
        if handshake == nil { handshake = try parser.consume(data) }
        // After readiness, stderr continues to be drained but is never retained or logged.
    }
}
