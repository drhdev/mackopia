import BackupDomain
import SwiftUI

/// Keep draft input alive while connection observations refresh the presenting window.
struct LocalSetupSheet: View {
    @State private var store: LocalSetupStore

    init(connection: AgentConnection, credentialRepository: Repository? = nil) {
        _store = State(
            initialValue: LocalSetupStore(connection: connection, credentialRepository: credentialRepository))
    }

    var body: some View { LocalSetupView().environment(store) }
}

#Preview { LocalSetupSheet(connection: PreviewData.connection()) }
