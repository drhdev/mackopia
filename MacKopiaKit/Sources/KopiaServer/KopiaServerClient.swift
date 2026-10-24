import Foundation

/// Cookies and credentials stay private; complete policies use a bounded, redacted document.
package actor KopiaServerClient: KopiaBackupServing {
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

    package func close() {
        closed = true
        csrf = nil
        bootstrap?.cancel()
        bootstrap = nil
        bootstrapID = nil
        session.invalidateAndCancel()
    }

    package func repositoryStatus() async throws -> KopiaRepositoryStatus {
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

    package func sources() async throws -> KopiaSources {
        try await get(.sources)
    }

    func tasks() async throws -> KopiaTasks {
        try await get(.tasks)
    }

    func task(id: String) async throws -> KopiaTask {
        try await get(.task(id))
    }

    package func snapshots(source: KopiaSnapshotSource) async throws -> KopiaSnapshots {
        try await get(.snapshots(source))
    }

    package func snapshotManifests(source: KopiaSnapshotSource) async throws -> KopiaSnapshots {
        try await get(.snapshotManifests(source))
    }

    package func startUpload(source: KopiaSnapshotSource) async throws {
        try await changeUpload(.upload(source), source: source)
    }

    package func cancelUpload(source: KopiaSnapshotSource) async throws {
        try await changeUpload(.cancelUpload(source), source: source)
    }

    package func pinSnapshot(id: String) async throws -> KopiaSnapshot {
        let validID: (String) -> Bool = { value in
            !value.isEmpty && value.utf8.count <= 128
                && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard validID(id) else { throw KopiaServerClientError.invalidRequest }
        struct Request: Encodable { let snapshots: [String]; let addPins: [String] }
        // Kopia 0.23.1: pinning replaces the manifest ID; callers must use the returned snapshot.
        let body = try JSONEncoder().encode(Request(snapshots: [id], addPins: [Self.plausibilityPin]))
        let data = try await read(.editSnapshots, method: "POST", body: body)
        guard let snapshots = try? JSONDecoder().decode([KopiaSnapshot].self, from: data),
            snapshots.count == 1, let snapshot = snapshots.first,
            let newID = snapshot.id, validID(newID), snapshot.pins?.contains(Self.plausibilityPin) == true
        else { throw KopiaServerClientError.response }
        return snapshot
    }

    package static let plausibilityPin = "mackopia-plausibility"

    private func changeUpload(_ route: KopiaServerRoute, source: KopiaSnapshotSource) async throws {
        struct Result: Decodable { let success: Bool? }
        struct Response: Decodable { let sources: [String: Result]? }
        let data = try await read(route, method: "POST", body: Data("{}".utf8))
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
            let results = response.sources, results.count == 1,
            results[source.userName + "@" + source.host + ":" + source.path]?.success == true
        else { throw KopiaServerClientError.response }
    }

    func policy(source: KopiaSnapshotSource) async throws -> KopiaPolicy? {
        do { return try await get(.policy(source)) } catch KopiaServerClientError.policyNotFound {
            try Task.checkCancellation()
            guard !closed else { throw KopiaServerClientError.closed }
            return nil
        }
    }

    /// Complete definition for a later merge, bound to the exact request selector. No inheritance resolution.
    package func policyDefinition(source: KopiaSnapshotSource) async throws -> KopiaSourcePolicyDefinition? {
        do {
            let data = try await read(.policy(source), maximumBytes: KopiaPolicyDocument.maximumBytes)
            let document: KopiaPolicyDocument
            do { document = try KopiaPolicyDocument(data: data) } catch { throw KopiaServerClientError.response }
            try Task.checkCancellation()
            return KopiaSourcePolicyDefinition(source: source, document: document)
        } catch KopiaServerClientError.policyNotFound {
            try Task.checkCancellation()
            guard !closed else { throw KopiaServerClientError.closed }
            return nil
        }
    }

    func resolvePolicy(source: KopiaSnapshotSource) async throws -> KopiaResolvedPolicy {
        try await get(.resolvePolicy(source))
    }

    /// Kopia 0.23.1: resolve with updates computes inheritance without persisting the proposal.
    package func previewPolicy(
        source: KopiaSnapshotSource, updates: KopiaPolicyDocument?
    ) async throws -> KopiaPolicyDocument {
        var body = Data(#"{"numUpcomingSnapshotTimes":0"#.utf8)
        if let updates { body.append(Data(",\"updates\":".utf8)); body.append(try updates.encoded()) }
        body.append(125)
        let data = try await read(.resolvePolicy(source), body: body)
        do {
            let response = try KopiaPolicyDocument(data: data)
            if let error = response.value(for: "schedulingError"), error != Data("\"\"".utf8),
                error != Data("null".utf8)
            {
                throw KopiaServerClientError.response
            }
            guard let effective = response.value(for: "effective") else { throw KopiaServerClientError.response }
            return try KopiaPolicyDocument(data: effective)
        } catch { throw KopiaServerClientError.response }
    }

    package func replacePolicy(source: KopiaSnapshotSource, document: KopiaPolicyDocument) async throws {
        _ = try await read(.policy(source), method: "PUT", body: document.encoded())
    }

    func directory(id: String) async throws -> KopiaDirectory {
        let directory: KopiaDirectory = try await get(.directory(id))
        guard directory.stream == "kopia:directory" else { throw KopiaServerClientError.response }
        return directory
    }

    private func get<Response: Decodable & Sendable>(_ route: KopiaServerRoute) async throws -> Response {
        let data = try await read(route)
        do { return try JSONDecoder().decode(Response.self, from: data) } catch {
            throw KopiaServerClientError.response
        }
    }

    private func read(
        _ route: KopiaServerRoute, maximumBytes: Int = 4 * 1024 * 1024,
        method: String? = nil, body: Data? = nil
    ) async throws -> Data {
        var request = try Self.request(handshake: handshake, route: route)
        if let method { request.httpMethod = method }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let csrf = try await authenticate()
        guard !closed else { throw KopiaServerClientError.closed }
        request.setValue("Kopia-Session-Cookie=" + csrf.cookie, forHTTPHeaderField: "Cookie")
        request.setValue(csrf.token, forHTTPHeaderField: "X-Kopia-CSRF-Token")
        let allowsMissingPolicy: Bool
        if case .policy = route, method == nil { allowsMissingPolicy = true } else { allowsMissingPolicy = false }
        let (_, data) = try await Self.read(
            session: session, request: request, allowsMissingPolicy: allowsMissingPolicy, maximumBytes: maximumBytes)
        try Task.checkCancellation()
        guard !closed else { throw KopiaServerClientError.closed }
        return data
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
        if case .resolvePolicy = route {
            // Kopia 0.23.1: resolve is a read-only POST. No updates or Kopia scheduling requests.
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(#"{"numUpcomingSnapshotTimes":0}"#.utf8)
        }
        return request
    }

    private static func read(
        session: URLSession, request: URLRequest, allowsMissingPolicy: Bool = false, maximumBytes: Int = 4 * 1024 * 1024
    ) async throws -> (HTTPURLResponse, Data) {
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
            // Kopia 0.23.1: GET /policy returns HTTP 400 + NOT_FOUND for an undefined policy.
            let missingPolicy = allowsMissingPolicy && response.statusCode == 400
            guard response.statusCode == 200 || missingPolicy else { throw KopiaServerClientError.response }
            let limit = maximumBytes
            guard response.expectedContentLength <= limit else { throw KopiaServerClientError.responseTooLarge }
            var body = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard body.count < limit else { throw KopiaServerClientError.responseTooLarge }
                body.append(byte)
            }
            if missingPolicy {
                struct ErrorCode: Decodable { let code: String }
                guard let code = try? JSONDecoder().decode(ErrorCode.self, from: body), code.code == "NOT_FOUND" else {
                    throw KopiaServerClientError.response
                }
                throw KopiaServerClientError.policyNotFound
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
