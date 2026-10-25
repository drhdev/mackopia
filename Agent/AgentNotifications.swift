import BackupDomain
import Foundation
import UserNotifications

/// Notification payloads carry only fixed copy and a plan UUID. No paths or process diagnostics.
@MainActor
final class AgentNotifications: NSObject, UNUserNotificationCenterDelegate {
    var retry: ((UUID) -> Void)?
    var openDetails: (() -> Void)?
    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard

    override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "problem",
                actions: [
                    UNNotificationAction(identifier: "retry", title: String(localized: "Erneut versuchen")),
                    UNNotificationAction(
                        identifier: "details", title: String(localized: "Details anzeigen"), options: .foreground),
                ], intentIdentifiers: [])
        ])
    }

    func requestPermission() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func received(_ state: LocalServiceState) async {
        guard state.configuration?.notificationsEnabled == true else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        for plan in state.plans {
            let key = "notification.problem." + plan.planID.uuidString
            let first = "notification.firstSuccess." + plan.planID.uuidString
            switch BackupNotificationPolicy.decision(
                plan: plan, now: .now,
                lastProblem: defaults.object(forKey: key) as? Date, firstSuccessSent: defaults.bool(forKey: first))
            {
            case .problem:
                if await post(plan.planID, problem: true) { defaults.set(Date.now, forKey: key) }
            case .firstSuccess:
                if await post(plan.planID, problem: false) { defaults.set(true, forKey: first) }
            case nil: break
            }
        }
    }

    private func post(_ id: UUID, problem: Bool) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title =
            problem
            ? String(localized: "Backup benötigt Aufmerksamkeit") : String(localized: "Erstes Backup abgeschlossen")
        content.body =
            problem
            ? String(localized: "Prüfe den Status in MacKopia. Dort findest du den nächsten Schritt.")
            : String(localized: "Deine Daten wurden gesichert. Den Prüfstatus findest du in MacKopia.")
        content.categoryIdentifier = problem ? "problem" : "success"
        content.userInfo = ["planID": id.uuidString]
        do {
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return true
        } catch { return false }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let id = (response.notification.request.content.userInfo["planID"] as? String).flatMap(UUID.init(uuidString:))
        let retryRequested = response.actionIdentifier == "retry"
        await MainActor.run {
            if retryRequested, let id { retry?(id) } else { openDetails?() }
        }
    }
}
