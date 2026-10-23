import Darwin
import Foundation

/// Finite CLI commands only. Long-lived server stdin/handshake/PID-file ownership is a separate API.
actor KopiaProcess: KopiaProcessRunning {
    private let clock: any Clock<Duration>
    private let interruptGrace: Duration
    private let terminateGrace: Duration

    init(
        clock: any Clock<Duration> = ContinuousClock(),
        interruptGrace: Duration = .seconds(10), terminateGrace: Duration = .seconds(10)
    ) {
        self.clock = clock
        self.interruptGrace = interruptGrace
        self.terminateGrace = terminateGrace
    }

    func run(_ input: KopiaProcessRequest) async throws -> KopiaProcessResult {
        try Task.checkCancellation()
        let request = try Self.validated(input)
        let control = KopiaProcessControl()
        let clock = self.clock
        let interruptGrace = self.interruptGrace
        let terminateGrace = self.terminateGrace
        // The lifecycle task must remain alive until reaping, even if the caller is cancelled.
        let lifecycle = Task.detached {
            try await Self.execute(
                request, control: control, clock: clock,
                interruptGrace: interruptGrace, terminateGrace: terminateGrace)
        }
        return try await withTaskCancellationHandler {
            try await lifecycle.value
        } onCancel: {
            control.stop(.cancelled)
        }
    }

    static func validated(_ input: KopiaProcessRequest) throws -> KopiaProcessRequest {
        let allowed = Set([
            "HOME", "USER", "LANG", "LC_ALL", "TMPDIR", "KOPIA_CHECK_FOR_UPDATES",
            "KOPIA_PASSWORD", "KOPIA_LOG_DIR", "KOPIA_CACHE_DIRECTORY",
            "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_REGION", "AWS_DEFAULT_REGION",
            "KOPIA_WEBDAV_USERNAME", "KOPIA_WEBDAV_PASSWORD",
        ])
        guard input.executable.isFileURL, !input.executable.path.utf8.contains(0),
            input.arguments.count <= 256, input.arguments.allSatisfy({ !$0.utf8.contains(0) }),
            input.environment.allSatisfy({ allowed.contains($0.key) && !$0.value.utf8.contains(0) }),
            input.environment["HOME"]?.hasPrefix("/") == true,
            input.environment["TMPDIR"]?.hasPrefix("/") == true,
            input.environment["KOPIA_LOG_DIR"]?.hasPrefix("/") == true,
            input.environment["KOPIA_CACHE_DIRECTORY"]?.hasPrefix("/") == true,
            input.timeout > .zero, input.outputLimit > 0, input.outputLimit <= 64 * 1024 * 1024,
            (input.webDAVConfiguration == nil) == (input.repositoryDirectory == nil)
        else { throw KopiaProcessError.invalidRequest }
        var result = input
        result.environment["LANG"] = "en_US.UTF-8"
        result.environment["LC_ALL"] = "en_US.UTF-8"
        result.environment["KOPIA_CHECK_FOR_UPDATES"] = "false"
        return result
    }

    private static func execute<C: Clock>(
        _ request: KopiaProcessRequest, control: KopiaProcessControl, clock: C,
        interruptGrace: Duration, terminateGrace: Duration
    ) async throws -> KopiaProcessResult where C.Duration == Duration {
        if control.reason != nil { throw CancellationError() }
        let configuration: KopiaConfigurationPipe?
        if let payload = request.webDAVConfiguration, let directory = request.repositoryDirectory {
            configuration = try KopiaConfigurationPipe(payload: payload, repositoryDirectory: directory, clock: clock)
        } else {
            configuration = nil
        }
        defer { configuration?.close() }
        let child = try KopiaChildProcess.launch(request, configuration: configuration)
        configuration?.didLaunch()
        async let output = capture(child.output, limit: request.outputLimit, control: control, clock: clock)
        async let error = capture(child.error, limit: request.outputLimit, control: control, clock: clock)
        let started = clock.now
        var stopped: C.Instant?
        var stage = 0
        let exitCode: Int32
        do {
            while true {
                if let status = try child.reapIfExited() {
                    exitCode = status
                    break
                }
                if clock.now >= started.advanced(by: request.timeout) { control.stop(.timedOut) }
                if control.reason != nil {
                    if stopped == nil {
                        child.signal(SIGINT)
                        stopped = clock.now
                    } else if let stopped, stage == 0, clock.now >= stopped.advanced(by: interruptGrace) {
                        child.signal(SIGTERM)
                        stage = 1
                    } else if let stopped, stage == 1,
                        clock.now >= stopped.advanced(by: interruptGrace + terminateGrace)
                    {
                        child.signal(SIGKILL)
                        stage = 2
                    }
                }
                do {
                    try await clock.sleep(for: .milliseconds(10))
                } catch {
                    control.stop(.ioFailure)
                    child.signal(SIGKILL)
                    try? await ContinuousClock().sleep(for: .milliseconds(10))
                }
            }
        } catch {
            // waitid failures mean ownership can no longer be established; never signal a reused PID.
            control.didExit()
            _ = await (output, error)
            throw KopiaProcessError.waitFailed
        }
        control.didExit()
        let captured = await (output, error)
        switch control.reason {
        case .cancelled: throw CancellationError()
        case .timedOut: throw KopiaProcessError.timedOut
        case .outputLimit: throw KopiaProcessError.outputLimitExceeded
        case .ioFailure: throw KopiaProcessError.ioFailed
        case nil: break
        }
        // A process that rejects the input may close the pipe early; its failure is returned intact.
        if exitCode == 0 { try await configuration?.waitForDelivery() }
        return KopiaProcessResult(exitCode: exitCode, standardOutput: captured.0, standardError: captured.1)
    }

    private static func capture<C: Clock>(
        _ descriptor: Int32, limit: Int, control: KopiaProcessControl, clock: C
    ) async -> Data where C.Duration == Duration {
        defer { Darwin.close(descriptor) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 32_768)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let available = limit - data.count
                data.append(contentsOf: buffer.prefix(min(count, available)))
                if count > available { control.stop(.outputLimit) }
                if control.exited && data.count == limit { return data }
                await Task.yield()
            } else if count == 0 {
                return data
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                if control.exited { return data }
                do {
                    try await clock.sleep(for: .milliseconds(10))
                } catch {
                    control.stop(.ioFailure)
                    try? await ContinuousClock().sleep(for: .milliseconds(10))
                }
            } else {
                control.stop(.ioFailure)
                return data
            }
        }
    }
}
