protocol KopiaProcessRunning: Sendable {
    func run(_ request: KopiaProcessRequest) async throws -> KopiaProcessResult
}
