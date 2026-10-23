import Darwin
import Foundation

/// Owns a finite command's child. Never expose the PID or signal a PID after reaping it.
struct KopiaChildProcess: Sendable {
    let pid: pid_t
    let output: Int32
    let error: Int32

    static func launch(_ request: KopiaProcessRequest, configuration: KopiaConfigurationPipe?) throws -> Self {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw KopiaProcessError.launchFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw KopiaProcessError.launchFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        var descriptors: [Int32] = []
        var launched = false
        defer {
            for (index, descriptor) in descriptors.enumerated() where !launched || index % 2 == 1 {
                Darwin.close(descriptor)
            }
        }
        for _ in 0..<2 {
            var pipe: [Int32] = [-1, -1]
            guard Darwin.pipe(&pipe) == 0 else { throw KopiaProcessError.launchFailed }
            let reader = fcntl(pipe[0], F_DUPFD_CLOEXEC, 4)
            let writer = fcntl(pipe[1], F_DUPFD_CLOEXEC, 4)
            for descriptor in pipe { Darwin.close(descriptor) }
            guard reader >= 0, writer >= 0 else {
                if reader >= 0 { Darwin.close(reader) }
                if writer >= 0 { Darwin.close(writer) }
                throw KopiaProcessError.launchFailed
            }
            descriptors += [reader, writer]
        }
        var mask = sigset_t()
        var defaults = sigset_t()
        sigemptyset(&mask)
        sigfillset(&defaults)
        guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0,
            fcntl(descriptors[2], F_SETFL, O_NONBLOCK) == 0,
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
            posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO) == 0,
            posix_spawn_file_actions_adddup2(&actions, descriptors[3], STDERR_FILENO) == 0,
            posix_spawnattr_setflags(
                &attributes,
                Int16(
                    POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
                )) == 0,
            posix_spawnattr_setpgroup(&attributes, 0) == 0,
            posix_spawnattr_setsigmask(&attributes, &mask) == 0,
            posix_spawnattr_setsigdefault(&attributes, &defaults) == 0
        else { throw KopiaProcessError.launchFailed }
        if let configuration {
            guard
                posix_spawn_file_actions_adddup2(
                    &actions, configuration.readDescriptor, KopiaConfigurationPipe.childDescriptor) == 0
            else { throw KopiaProcessError.launchFailed }
        }
        var arguments = [request.executable.path] + request.arguments
        if let configuration { arguments.append("--config-file=" + configuration.configurationURL.path) }
        let argumentPointers = arguments.map { strdup($0) }
        let environmentPointers = request.environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) }
        defer {
            argumentPointers.forEach { free($0) }
            environmentPointers.forEach { free($0) }
        }
        guard argumentPointers.allSatisfy({ $0 != nil }), environmentPointers.allSatisfy({ $0 != nil }) else {
            throw KopiaProcessError.launchFailed
        }
        var argv = argumentPointers + [nil]
        var environment = environmentPointers + [nil]
        var pid: pid_t = 0
        guard posix_spawn(&pid, request.executable.path, &actions, &attributes, &argv, &environment) == 0 else {
            throw KopiaProcessError.launchFailed
        }
        launched = true
        return Self(pid: pid, output: descriptors[0], error: descriptors[2])
    }

    func signal(_ value: Int32) { kill(-pid, value) }

    func reapIfExited() throws -> Int32? {
        var info = siginfo_t()
        let observed = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if observed < 0 {
            if errno == EINTR { return nil }
            throw KopiaProcessError.waitFailed
        }
        guard info.si_pid == pid else { return nil }
        // Keep the leader unreaped until all remaining group members have been stopped. This
        // avoids signaling a reused PID/group after the leader exits while descendants hold pipes.
        signal(SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else { throw KopiaProcessError.waitFailed }
        }
        let terminationSignal = status & 0x7f
        return terminationSignal == 0 ? (status >> 8) & 0xff : 128 + terminationSignal
    }
}
