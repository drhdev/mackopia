import Foundation

struct KopiaCommandRunner: Sendable {
    let process: any KopiaProcessRunning

    func run(_ command: KopiaCommand, context: KopiaExecutionContext) async throws -> Data {
        let result = try await process.run(context.request(for: command))
        guard result.exitCode == 0 else { throw KopiaProcessError.commandFailed(exitCode: result.exitCode) }
        return result.standardOutput
    }
}
