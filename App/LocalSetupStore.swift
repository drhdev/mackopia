import BackupDomain
import Foundation
import Observation

@Observable @MainActor
final class LocalSetupStore {
    let connection: AgentConnection
    var name = ""
    var sourceSelection: BackupSource?
    var destinationSelection: BackupSource?
    var source: String { sourceSelection?.path ?? "" }
    var destination: String { destinationSelection?.path ?? "" }
    var password = ""
    var confirmation = ""
    var create = true
    var repositoryID: UUID?
    var revealPassword = false

    init(connection: AgentConnection) { self.connection = connection }
    var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 1024
            && !source.isEmpty
            && (repositoryID != nil
                || (!destination.isEmpty && !password.isEmpty
                    && password.utf8.count <= 65_536
                    && (!create || (password.count >= 12 && password == confirmation))))
    }
    func selectSource() { connection.chooseDirectory { self.sourceSelection = $0 } }
    func selectDestination() { connection.chooseDirectory { self.destinationSelection = $0 } }
    func generatePassword() {
        password = UUID().uuidString + UUID().uuidString; confirmation = password; revealPassword = true
    }
    func clear() { password = ""; confirmation = ""; revealPassword = false }
    func submit(completed: @escaping () -> Void) {
        guard valid, let source = sourceSelection else { return }
        if let repositoryID {
            connection.send(.createPlan(name: name, repositoryID: repositoryID, source: source), completed: completed)
            return
        }
        guard let destination = destinationSelection else { return }
        connection.send(
            .setup(name: name, destination: destination, source: source, password: password, create: create)
        ) {
            self.connection.recoveryKitRepositoryID =
                self.connection.state?.configuration?.repositories.first {
                    if case .filesystem(let path, _) = $0.kind { return path == destination.path }
                    return false
                }?.id
            self.clear(); completed()
        }
    }
    func cancel() { connection.cancelOperation(); clear() }
}
