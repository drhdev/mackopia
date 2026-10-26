import BackupDomain
import SwiftUI

/// The draft belongs to the presentation, not to each render of the parent window.
struct PlanEditorSheet: View {
    @State private var store: PlanEditorStore

    init(plan: BackupPlan, connection: AgentConnection) {
        _store = State(initialValue: PlanEditorStore(plan: plan, connection: connection))
    }

    var body: some View { PlanEditorView().environment(store) }
}

#Preview {
    let connection = PreviewData.connection()
    if let plan = connection.state?.configuration?.plans.first {
        PlanEditorSheet(plan: plan, connection: connection)
    }
}
