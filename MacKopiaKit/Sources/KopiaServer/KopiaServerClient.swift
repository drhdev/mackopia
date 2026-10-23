import Foundation

/// Cookies, credentials and raw bodies never cross the module boundary.
actor KopiaServerClient {
    private let handshake: KopiaServerHandshake
    private let session: URLSession
    private var csrf: KopiaServerCSRFSession?
    private var bootstrap: Task<KopiaServerCSRFSession, any Error>?
    private var bootstrapID: UUID?
    private var closed = false

    init(handshake: KopiaServerHandshake) {
        self.handshake = handshake
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv13
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        session = URLSession(
            configuration: configuration, delegate: KopiaServerTrustDelegate(handshake: handshake), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func close() {
        closed = true
        csrf = nil
        bootstrap?.cancel()
        bootstrap = nil
        bootstrapID = nil
        session.invalidateAndCancel()
    }

    func repositoryStatus() async throws -> KopiaRepositoryStatus {
        try await get(.repositoryStatus)
    }

    /// Secondary graceful shutdown path; stdin EOF remains the process owner's primary mechanism.
    func shutdownServer() async throws {
        try Task.checkCancellation()
        guard !closed else { throw KopiaServerClientError.closed }
        var request = URLRequest(url: handshake.address.appendingPathComponent("api/v1/control/shutdown"))
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let credentials = Data(("server-control:" + handshake.controlPassword).utf8).base64EncodedString()
        request.setValue("Basic " + credentials, forHTTPHeaderField: "Authorization")
        // Kopia 0.23.1: control uses its own credentials and must not receive the UI CSRF session.
        _ = try await Self.read(session: session, request: request)
        try Task.checkCancellation()
        guard !closed else { throw KopiaServerClientError.closed }
    }

    func sources() async throws -> KopiaSources {
        try await get(.sources)
    }

    func tasks() async throws -> KopiaTasks {
        try await get(.tasks)
    }

    func task(id: String) async throws -> KopiaTask {
        try await get(.task(id))
    }

    func snapshots(source: KopiaSnapshotSource) async throws -> KopiaSnapshots {
        try await get(.snapshots(source))
    }

    func directory(id: String) async throws -> KopiaDirectory {
        let directory: KopiaDirectory = try await get(.directory(id))
        guard directory.stream == "kopia:directory" else { throw KopiaServerClientError.response }
        return directory
    }

    private func get<Response: Decodable & Sendable>(_ route: KopiaServerRoute) async throws -> Response {
        var request = try Self.request(handshake: handshake, route: route)
        let csrf = try await authenticate()
        guard !closed else { throw KopiaServerClientError.closed }
        request.setValue("Kopia-Session-Cookie=" + csrf.cookie, forHTTPHeaderField: "Cookie")
        request.setValue(csrf.token, forHTTPHeaderField: "X-Kopia-CSRF-Token")
        let (_, data) = try await Self.read(session: session, request: request)
        try Task.checkCancellation()
        guard !closed else { throw KopiaServerClientError.closed }
        do { return try JSONDecoder().decode(Response.self, from: data) } catch {
            throw KopiaServerClientError.response
        }
    }

    private func authenticate() async throws -> KopiaServerCSRFSession {
        try Task.checkCancellation()
        guard !closed else { throw KopiaServerClientError.closed }
        if let csrf { return csrf }
        let task: Task<KopiaServerCSRFSession, any Error>
        let identifier: UUID
        if let bootstrap, let bootstrapID {
            task = bootstrap
            identifier = bootstrapID
        } else {
            let session = self.session
            let handshake = self.handshake
            task = Task {
                let (response, body) = try await Self.read(
                    session: session, request: Self.request(handshake: handshake, route: .root))
                return try KopiaServerCSRFSession(response: response, body: body, address: handshake.address)
            }
            bootstrap = task
            identifier = UUID()
            bootstrapID = identifier
        }
        do {
            // A cancelled waiter cancels this shared bootstrap; other waiters may retry afterwards.
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard !closed else { throw KopiaServerClientError.closed }
            if bootstrapID == identifier {
                csrf = result
                bootstrap = nil
                bootstrapID = nil
            }
            return result
        } catch {
            if bootstrapID == identifier { bootstrap = nil; bootstrapID = nil }
            throw error
        }
    }

    private static func request(handshake: KopiaServerHandshake, route: KopiaServerRoute) throws -> URLRequest {
        var request = URLRequest(url: try route.url(relativeTo: handshake.address))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let credentials = Data(("mackopia:" + handshake.password).utf8).base64EncodedString()
        request.setValue("Basic " + credentials, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func read(session: URLSession, request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        do {
            guard let delegate = session.delegate as? KopiaServerTrustDelegate else {
                throw KopiaServerClientError.transport
            }
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse, response.url == request.url else {
                throw KopiaServerClientError.response
            }
            if response.statusCode == 401 { throw KopiaServerClientError.authentication }
            guard response.statusCode == 200 else { throw KopiaServerClientError.response }
            let limit = 4 * 1024 * 1024
            guard response.expectedContentLength <= limit else { throw KopiaServerClientError.responseTooLarge }
            var body = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard body.count < limit else { throw KopiaServerClientError.responseTooLarge }
                body.append(byte)
            }
            return (response, body)
        } catch let error as KopiaServerClientError { throw error } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw KopiaServerClientError.transport
        }
    }
}
