import SwiftUI

@main
struct AgentApp: App {
    @NSApplicationDelegateAdaptor(AgentAppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("MacKopia", systemImage: delegate.runtime.statusSymbol) {
            AgentStatusView().environment(delegate.runtime)
        }
        .menuBarExtraStyle(.window)
    }
}
