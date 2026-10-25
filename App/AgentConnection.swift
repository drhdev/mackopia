import AgentProtocol
import AppKit
import BackupDomain
import Observation

@Observable @MainActor
final class AgentConnection {
    var state: LocalServiceState?
    var connected = false
    var busy = false
    var message: String?
    var showSetup = false
    var showRecovery = false
    var showActivity = false
    var showRestore = false
    var recoveryKitRepositoryID: UUID?
    var editingPlan: BackupPlan?
    private var client: AgentServiceClient?
    private var registration: AgentServiceRegistration?
    private var commandTask: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private let preview: Bool

    init(preview: Bool = false) {
        self.preview = preview
        guard !preview else { return }
        if let id = Bundle.main.bundleIdentifier, let identity = try? AgentServiceIdentity(appBundleID: id) {
            client = AgentServiceClient(identity: identity)
            registration = AgentServiceRegistration(identity: identity)
        }
    }

    var requiresApproval: Bool { registration?.status == .requiresApproval }
    var canConfigure: Bool {
        connected && !busy && !showSetup && editingPlan == nil && state?.configuration != nil
            && state?.activePlanID == nil && state?.restore?.phase != .running
    }
    var canRun: Bool { canConfigure && !(state?.configuration?.plans.isEmpty ?? true) }

    func start() {
        guard !preview, observation == nil else { return }
        observation = Task { [weak self] in
            guard let self, let client else { return }
            var revision: UUID?
            while !Task.isCancelled {
                do {
                    let state = try await client.send(.state(after: revision))
                    guard !Task.isCancelled else { return }
                    self.state = state
                    connected = true
                    revision = state.revision
                    if !busy { message = state.issue.map(Self.description) }
                } catch {
                    if Task.isCancelled { return }
                    connected = false
                    message = Self.description(.unavailable)
                    revision = nil
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
        }
    }
    func enable() {
        do { try registration?.register(); reconnect() } catch { message = Self.description(.unavailable) }
    }
    func reconnect() { observation?.cancel(); observation = nil; start() }
    func openLoginSettings() { registration?.openLoginItemsSettings() }
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
    func send(_ command: AgentRequest.Command, completed: @escaping () -> Void = {}) {
        guard !busy, let client else { return }
        busy = true
        observation?.cancel()
        observation = nil
        commandTask = Task {
            var succeeded = false
            do {
                state = try await client.send(command)
                connected = true
                message = state?.issue.map(Self.description)
                succeeded = true
            } catch { message = Self.description(error as? LocalServiceIssue ?? .unavailable) }
            busy = false; commandTask = nil; start()
            if succeeded { completed() }
        }
    }
    func cancelOperation() { commandTask?.cancel() }
    func runSelected(_ id: UUID? = nil) {
        guard let id = id ?? state?.configuration?.plans.first?.id else { return }
        send(.run(id))
    }
    func pause(_ option: BackupPauseOption, planID: UUID? = nil) {
        do { send(.pause(planID: planID, until: try option.deadline(after: .now))) } catch {
            message = Self.description(.invalidRequest)
        }
    }
    func resume(_ planID: UUID? = nil) { send(.resume(planID: planID)) }
    func stop() {
        if state?.restore?.phase == .running, let id = state?.restore?.operationID {
            send(.cancelRestore(id))
        } else if let id = state?.activePlanID {
            send(.stop(id))
        }
    }

    func chooseDirectory(completion: @escaping (BackupSource) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        Task {
            do {
                let source = try await Task.detached {
                    let url = selected.resolvingSymlinksInPath()
                    let values = try url.resourceValues(forKeys: [
                        .isDirectoryKey, .volumeUUIDStringKey, .volumeNameKey, .volumeIsRemovableKey, .volumeIsLocalKey,
                    ])
                    guard values.isDirectory == true, values.volumeIsLocal == true, let uuid = values.volumeUUIDString
                    else {
                        throw LocalServiceIssue.destination
                    }
                    return try BackupSource(
                        path: url.path,
                        volume: VolumeIdentity(
                            uuid: uuid, name: values.volumeName ?? "Volume",
                            isRemovable: values.volumeIsRemovable ?? false, isNetwork: false))
                }.value
                completion(source)
            } catch { message = Self.description(.destination) }
        }
    }

    func defaultRestoreDestination() async -> BackupSource? {
        guard !preview else { return nil }
        return await Task.detached { () -> BackupSource? in
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            let url = directory.resolvingSymlinksInPath()
            guard
                let values = try? url.resourceValues(forKeys: [
                    .isDirectoryKey, .volumeUUIDStringKey, .volumeNameKey,
                    .volumeIsRemovableKey, .volumeIsLocalKey,
                ]),
                values.isDirectory == true, values.volumeIsLocal == true, let uuid = values.volumeUUIDString
            else { return nil }
            return try? BackupSource(
                path: url.path,
                volume: VolumeIdentity(
                    uuid: uuid, name: values.volumeName ?? "Volume",
                    isRemovable: values.volumeIsRemovable ?? false, isNetwork: false))
        }.value
    }

    func lastSuccess(_ id: UUID) -> JobRun? {
        state?.runs.first { $0.planID == id && ($0.outcome == .succeeded || $0.outcome == .succeededWithWarnings) }
    }

    static func outcome(_ outcome: JobRun.Outcome) -> String {
        switch outcome {
        case .running: String(localized: "Backup läuft")
        case .succeeded: String(localized: "Erfolgreich")
        case .succeededWithWarnings: String(localized: "Mit Hinweisen abgeschlossen")
        case .skipped: String(localized: "Übersprungen")
        case .cancelled: String(localized: "Abgebrochen")
        case .failed: String(localized: "Fehlgeschlagen")
        }
    }

    static func description(_ issue: LocalServiceIssue) -> String {
        switch issue {
        case .waitingConditions: String(localized: "Backup wartet auf passende Energie- oder Netzwerkbedingungen.")
        case .planPaused: String(localized: "Backup-Plan pausiert. Setze ihn fort, bevor du ein Backup startest.")
        case .automationUnavailable:
            String(localized: "Automatik angehalten. Starte den Hintergrunddienst neu und prüfe die Aktivität.")
        case .verificationFailed:
            String(
                localized: "Prüfung nicht erfolgreich. Prüfe Speicherziel und Aktivität und starte die Prüfung erneut.")
        case .maintenanceFailed:
            String(localized: "Wartung nicht abgeschlossen. Prüfe das Speicherziel und die Aktivität.")
        case .permissions:
            String(
                localized:
                    "Quellenzugriff nicht bestätigt. Erlaube MacKopia den Festplattenvollzugriff und versuche es erneut. Fehlen die Safari-Testdaten, kann der Zugriff noch nicht bestätigt werden."
            )
        case .safeMode:
            String(
                localized: "Konfiguration nicht lesbar. Backups bleiben gesperrt. Prüfe die Konfigurationssicherung.")
        case .keychain:
            String(localized: "Schlüsselbund nicht verfügbar. Entsperre deinen Schlüsselbund und versuche es erneut.")
        case .busy: String(localized: "Ein Vorgang läuft bereits. Warte bis zum Abschluss.")
        case .destination:
            String(
                localized:
                    "Speicherziel oder Quelle nicht verfügbar. Prüfe Laufwerk, Netzwerk, Ordner, freien Speicher und Backup-Passwort. Bei S3 kannst du unter Speicherziele die Zugangsdaten prüfen und aktualisieren. Nach einem abgebrochenen Anlegen kannst du das vorhandene Ziel verbinden."
            )
        case .invalidRequest: String(localized: "Eingaben ungültig. Prüfe Namen, Quellen und Speicherziel.")
        case .backupFailed:
            String(
                localized: "Backup nicht abgeschlossen. Prüfe Speicherziel und Berechtigungen und versuche es erneut.")
        case .unavailable:
            String(
                localized:
                    "Hintergrunddienst nicht aktiv. Aktiviere den Dienst oder verbinde dich erneut. Prüfe nach einer unterbrochenen Einrichtung zuerst den aktuellen Stand."
            )
        }
    }
}
