import SwiftUI

struct FoundationSettingsView: View {
    var body: some View {
        Form {
            Section {
                Text("Einstellungen folgen in einem späteren Entwicklungsschritt.")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 240)
    }
}

#Preview {
    FoundationSettingsView()
}
