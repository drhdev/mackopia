import Darwin
import Foundation
import Synchronization

/// Package-only process boundary for KopiaServer. The detached task is the sole PID/FD owner.
package actor KopiaServerTransport {
    private let control = KopiaProcessControl()
    private let shutdownRequested = KopiaServerShutdown()
    private let clock: any Clock<Duration>
    private let grace: Duration
    private var started = false

    package init(clock: any Clock<Duration> = ContinuousClock(), grace: Duration = .seconds(10)) {
        self.clock = clock
        self.grace = grace
    }

    package func shutdown() { shutdownRequested.request() }
    package func cancel() { control.stop(.cancelled) }

    package func run(
        executable: URL, arguments: [String], environment: [String: String],
        webDAVConfiguration: Data? = nil, repositoryDirectory: URL? = nil,
        standardError: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> Int32 {
        guard !started, grace > .zero else { throw KopiaProcessError.invalidRequest }
        started = true
        try Task.checkCancellation()
        let request = try KopiaProcess.validated(
            KopiaProcessRequest(
                executable: executable, arguments: arguments, environment: environment,
                webDAVConfiguration: webDAVConfiguration, repositoryDirectory: repositoryDirectory))
        let control = self.control
        let shutdownRequested = self.shutdownRequested
        let clock = self.clock
        let grace = self.grace
        let lifecycle = Task.detached {
            try await Self.execute(
                request, control: control, shutdownRequested: shutdownRequested, clock: clock,
                grace: grace, standardError: standardError)
        }
        return try await withTaskCancellationHandler {
            try await lifecycle.value
        } onCancel: {
            control.stop(.cancelled)
        }
    }

    private static func execute<C: Clock>(
        _ request: KopiaProcessRequest, control: KopiaProcessControl, shutdownRequested: KopiaServerShutdown,
        clock: C, grace: Duration, standardError: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> Int32 where C.Duration == Duration {
        if control.reason != nil { throw CancellationError() }
        let configuration: KopiaConfigurationPipe?
        if let payload = request.webDAVConfiguration, let directory = request.repositoryDirectory {
            configuration = try KopiaConfigurationPipe(payload: payload, repositoryDirectory: directory, clock: clock)
        } else {
            configuration = nil
        }
        defer { configuration?.close() }
        let child = try KopiaChildProcess.launch(request, configuration: configuration, keepInputOpen: true)
        configuration?.didLaunch()
        var input = child.input
        defer { if let input { Darwin.close(input) } }
        async let output: Void = drain(child.output, control: control, clock: clock, receive: nil)
        async let error: Void = drain(child.error, control: control, clock: clock, receive: standardError)
        var eofAt: C.Instant?
        var interruptAt: C.Instant?
        var stage = 0
        let exitCode: Int32
        do {
            while true {
                if let code = try child.reapIfExited() { exitCode = code; break }
                if (shutdownRequested.requested || control.reason != nil), let descriptor = input {
                    Darwin.close(descriptor)
                    input = nil
                    eofAt = clock.now
                }
                if control.reason != nil || eofAt.map({ clock.now >= $0.advanced(by: grace) }) == true {
                    if interruptAt == nil {
                        child.signal(SIGINT)
                        interruptAt = clock.now
                    } else if let interruptAt, stage == 0, clock.now >= interruptAt.advanced(by: grace) {
                        child.signal(SIGTERM)
                        stage = 1
                    } else if let interruptAt, stage == 1, clock.now >= interruptAt.advanced(by: grace + grace) {
                        child.signal(SIGKILL)
                        stage = 2
                    }
                }
                do { try await clock.sleep(for: .milliseconds(10)) } catch {
                    control.stop(.ioFailure)
                    child.signal(SIGKILL)
                    try? await ContinuousClock().sleep(for: .milliseconds(10))
                }
            }
        } catch {
            control.didExit()
            _ = await (output, error)
            throw KopiaProcessError.waitFailed
        }
        control.didExit()
        _ = await (output, error)
        switch control.reason {
        case .cancelled: throw CancellationError()
        case .ioFailure, .outputLimit, .timedOut: throw KopiaProcessError.ioFailed
        case nil: break
        }
        if exitCode == 0 { try await configuration?.waitForDelivery() }
        return exitCode
    }

    private static func drain<C: Clock>(
        _ descriptor: Int32, control: KopiaProcessControl, clock: C,
        receive: (@Sendable (Data) async throws -> Void)?
    ) async where C.Duration == Duration {
        defer { Darwin.close(descriptor) }
        var buffer = [UInt8](repeating: 0, count: 8192)
        var failed = false
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                if let receive, !failed {
                    do { try await receive(Data(buffer.prefix(count))) } catch {
                        failed = true; control.stop(.ioFailure)
                    }
                }
                if control.exited { return }
                await Task.yield()
            } else if count == 0 {
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                if control.exited { return }
                do { try await clock.sleep(for: .milliseconds(10)) } catch {
                    control.stop(.ioFailure)
                    try? await ContinuousClock().sleep(for: .milliseconds(10))
                }
            } else {
                control.stop(.ioFailure); return
            }
        }
    }
}

private final class KopiaServerShutdown: Sendable {
    private let value = Mutex(false)
    var requested: Bool { value.withLock { $0 } }
    func request() { value.withLock { $0 = true } }
}
