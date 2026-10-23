import SwiftUI

struct AgentStatusView: View {
    var body: some View {
        VStack(alignment: .leading) {
            Label("Noch keine Backups eingerichtet", systemImage: "info.circle")
            Text("Der Hintergrunddienst wird vorbereitet.")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    AgentStatusView()
}
