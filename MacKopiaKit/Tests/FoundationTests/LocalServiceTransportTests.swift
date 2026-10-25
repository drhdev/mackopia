import BackupDomain
import Foundation
import Testing
import XPC

@testable import AgentProtocol

struct LocalServiceTransportTests {
    @Test func nativeXPCTransportsTheProductionAsyncPeerAndBoundedEnvelope() async throws {
        let expected = LocalServiceState(configuration: try BackupConfiguration())
        // Anonymous endpoint is confined to this process/test. Production always pins bundle code hashes.
        let listener = XPCListener { request in
            request.accept { session in ServicePeer(session: session, handle: { _ in expected }) }
        }
        defer { listener.cancel() }
        let exchange = ServiceExchange()
        let request = AgentRequest(.state(after: nil))
        let session = try XPCSession(
            endpoint: listener.endpoint,
            incomingMessageHandler: { (packet: AgentWirePacket) -> (any Encodable)? in
                do {
                    let response = try packet.decode(AgentResponse.self)
                    guard response.id == request.id, let state = response.state else {
                        throw AgentServiceError.invalidReply
                    }
                    exchange.finish(.success(state))
                } catch { exchange.finish(.failure(error)) }
                return nil
            }, cancellationHandler: { _ in exchange.finish(.failure(AgentServiceError.unavailable)) })
        defer { session.cancel(reason: "Test complete") }
        let timeout = Task {
            do {
                try await Task.sleep(for: .seconds(5))
                exchange.finish(.failure(AgentServiceError.timedOut))
            } catch {}
        }
        defer { timeout.cancel() }
        let state = try await withCheckedThrowingContinuation { continuation in
            exchange.install(continuation)
            do { try session.send(AgentWirePacket(request)) } catch { exchange.finish(.failure(error)) }
        }
        #expect(state.revision == expected.revision)
        #expect(state.configuration == expected.configuration)
    }
}
