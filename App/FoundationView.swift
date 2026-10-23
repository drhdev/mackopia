import SwiftUI

struct FoundationView: View {
    var body: some View {
        ContentUnavailableView(
            "MacKopia wird vorbereitet",
            systemImage: "externaldrive.badge.timemachine",
            description: Text("Backup-Funktionen werden in den nächsten Entwicklungsschritten eingerichtet.")
        )
        .frame(minWidth: 640, minHeight: 400)
    }
}

#Preview {
    FoundationView()
}
