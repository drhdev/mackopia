import SwiftUI

@main
struct MacKopiaApp: App {
    var body: some Scene {
        WindowGroup {
            FoundationView()
        }
        Settings {
            FoundationSettingsView()
        }
    }
}
