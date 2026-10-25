# Implementierungsatlas

Stand: 2026-10-25. Kompakter Codeatlas, keine Sessionchronik.
Normative Architektur: PROJEKT.md; aktiver Auftrag und Nachweise: STATUS.md.
Alte Phasen-/Batch-Nummern in Kommentaren und Protokollen sind historische Referenzen.

## Plattform und Architektur

- Nur macOS 27.x, natives arm64. Deployment Target 27.0 in Config/Shared.xcconfig und MacKopiaKit/Package.swift.
- Stabile Toolchain: aktuell Xcode 27.1 / Swift-Compiler 6.4 / Sprachmodus Swift 6 / SDK 27.
- SwiftUI/Observation/MainActor für UI-State; cancellable Actors/strukturierte Concurrency in Package und Dienst.
- App → AgentProtocol/XPC → Agent → BackupEngine → KopiaCLI/KopiaServer; keine Kopia-Imports in App.
- `AgentAppDelegate` besitzt einen `LocalBackupService`; lokale Einrichtung und manuelle Läufe teilen dessen Gate,
  ConfigStore, HistoryStore, Keychain und Laufwerksschutz. Die automatische Runtime ist noch nicht angeschlossen.
- Ad-hoc-Signaturen ohne Apple-Konto, aktive Hardened Runtime, keine zusätzlichen Entitlements.
- Xcode-Debug-Dylib deaktiviert; Produkttests außerhalb der App, ohne gelockerte Library Validation.

## Vorhandene Bausteine und Integrationsgrenzen

| Bereich | Implementiert / relevante Einstiegsstellen | Noch zu verbinden |
|---|---|---|
| Domain | BackupDomain: validierte Quellen/Ziele/Pläne, UUID-Identität, Policies, Lauf-/Prüfergebnisse | Version-2-Requests tragen validierte Domain-Auswahl einschließlich Volume-UUID |
| CLI | KopiaCLI: isolierte Prozesse, Whitelist-Umgebung, Timeout/Cancel/Reaping, begrenzte Pipes, Bootstrap/Binding, Verify, Restore-Stichprobe, Wartung lesen/ausführen | Lokaler Bootstrap/Backup im Dienst verdrahtet; Remote-Backends folgen |
| Server | KopiaServer: loopback TLS, Zertifikatspin, Auth/CSRF, REST, Shutdown/Abbruch | Manueller Dienst-Lifecycle verdrahtet; Restore-Browser an UI folgt |
| Konfiguration | Persistence/ConfigStore: atomare Konfiguration, Live-Reload-Grundlage | Dienstbesitz, validierte Mutationen und explizite Recovery über XPC verdrahtet |
| Historie | Persistence/HistoryStore + VerificationHistory: dauerhafte Läufe und artgetrennte Prüfnachweise | Jüngste Läufe über XPC/Aktivität verdrahtet; Wartungsevidenz fehlt |
| Secrets | Secrets/AgentKeychainStore → KeychainStore(): Login-Keychain, SecItem, Standard-App-ACL, LAContext ohne UI; alter Team-Adapter nur Vertragsbestand | Echte Agent-Keychain-/Update-Abnahme offen; kein Datei-Fallback |
| Schutz | BackupPreflight, BackupOperationCoordinator, RepositoryOperationGate, SystemIntegration | Lokaler Dienst verwendet gemeinsames Gate/Schutz; AgentFullDiskAccessProbe verlangt frische Agent-/Kopia-Leseevidenz. Installierte TCC-Zuordnung offen |
| Manuelle Engine | ManualBackupEngine, ConfiguredJobRunner, FilesystemBackupSessions, Policy-Abgleich | LocalBackupService → XPC → AgentConnection/Übersicht/Menüleiste verdrahtet |
| Automatik | AutomaticBackupRuntime/Controls/State, Scheduler, Monitore, Retry/Pausen/Recovery/Historienabgleich | Phase 2: als alleinigen Queue-/Engine-Besitzer in LocalBackupService übernehmen; weitere Planoptionen |
| Vertrauen | Health, Plausibilität/Pinning, SnapshotVerificationEngine, AutomaticSnapshotVerification, AutomaticTestRestore | Produktive Beobachtungen/UI; Wartungsnacharbeit und Mitteilungen |
| Wartung | MaintenanceCoordinator, FilesystemMaintenanceInspection, KopiaMaintenanceReader/Runner | Frische Owner-/Terminprüfung existiert; automatische Runtime-Nacharbeit und dauerhafte Evidenz fehlen |
| XPC | AgentSigningIdentity, AgentServiceClient/Server, AgentWirePacket/Request, AgentServiceRegistration; Version 2, Grenzen/Korrelation, asynchrone Antworten, Revisionsbeobachtung/Reconnect | Echter registrierter positiver/negativer Peer-Test; weitere Requests in Folgephasen |
| UI | App/AgentConnection, LocalSetupStore/View, PlanEditorStore/View, FoundationView/Settings, PreviewData; Agent/AgentRuntimeStore und echte Menüleiste; DE/EN | Automatik/Health/Restore; manueller Design-/A11y-Audit |
| System | UUID-Monitore, DiskArbitration-Schutz, Network/Energie/Wake, SleepAssertion | Live-Berechtigungsnachweise und gebündelte UI-/A11y-/Performance-Abnahme |

## Sicherheitsverträge, die beim Verbinden erhalten bleiben müssen

- Nur Agent führt Kopia aus; immer isolierte Config/Logs/Cache, nie Nutzer-Default-Konfiguration.
- Secrets nur Keychain/Prozess-Environment; WebDAV-Runtime-JSON ausschließlich in anonymer Pipe gemäß PROJEKT.md §6.2.
- XPC pinnt exakte Signing-ID und CodeDirectory-Hash aus validiertem App-/Agent-Bundle.
- Eigener laufender Code muss zum geprüften Disk-Siegel passen. Kein Team-ID-Zwang und kein ungeprüfter Transport.
- Gemeinsame Repo-Reservierung bis zum vollständigen Cancel-/Prozess-/Server-Cleanup halten.
- Frische Konfiguration, Preflight, Volume-UUIDs und Live-Laufwerksschutz vor realen Operationen prüfen.
- Quellen ohne ausreichenden FDA-/TCC-Nachweis nicht freigeben. Andere unabhängige Implementierung darf weitergehen.
- Restore überschreibt nie still; Wartung behält Kopias Sicherheitsdefaults. Keine unbestätigten destruktiven Kommandos.
- Fortschritt höchstens etwa viermal pro Sekunde; Ereignisquellen statt unnötigem Polling.

## Repräsentative Tests und Werkzeuge

- MacKopiaKit/Tests/FoundationTests/ManualBackupIntegrationTests.swift: echtes Temp-Ziel, zwei Quellen,
  Historie, Backup/Restore/Abbruch; VerifyIntegrationCheck ergänzt Prüfungen und echte fällige Full-Wartung.
- Automatic*Tests: simulierte Zeit/Ereignisse/Steuerung und serieller Prüf-Cleanup.
- AgentSigningIdentityTests.swift: echte temporäre Ad-hoc-Bundles, Manipulation/gleichnamiger fremder Code,
  Layout und laufender Eigenvergleich; keine permanente Dienstregistrierung.
- Tests/BundleLayoutTests.swift: gebautes Produkt, App-/Agent-/Kopia-Signaturen, Runtime und Plattformmetadaten.
- KopiaContractTests + Fixtures/kopia-0.23.1: bereinigte echte Kopia-Verträge.
- Scripts/tests: Download-Isolation, Architekturprüfung und Probe-Sicherheit; lange Scripts/spike-* nur bei Bedarf.
- LocalServiceIntegrationTests: echter temporärer Service-Lifecycle einschließlich Create/Connect, zusätzlichem
  Plan/Editor, Run, bytegleichem Restore, Reopen und Secret-Negativscan. LocalBackupServiceTests prüfen
  Safe Mode/Recovery, stale Volume-Auswahl und Cancellation; LocalServiceTransportTests echten nativen XPC-Peer.
- SchedulerTests.delayedTimerTaskRetainsTheOriginalMonotonicDeadline: Task-Start verzögert die Deadline nicht.
- Config/kopia-version.json bleibt auf 0.23.1 gepinnt. Historischer amd64-Hash ist keine Supportzusage;
  der aktuelle Fetch-/Embed-Pfad verwendet ausschließlich arm64, ohne lipo-Universal-Erzeugung.

## Bekannte technische Grenzen

- Lokaler manueller Nutzerworkflow ist verdrahtet und temporär integriert geprüft; installierte
  SMAppService-/Keychain-/FDA-Abnahme konnte ohne Computer-Use-Freigabe nicht durchgeführt werden.
- Neue Pläne haben nur manuelle Trigger; Editor: Name, Aktivierung, Quellen, Aufbewahrung. Automatik und
  weitere Optionen folgen in Phase 2, vollständige Restore-Oberfläche in Phase 3.
- FDA-Probe verlangt nichtleere reguläre Safari-Bookmarks ≤1 MiB. Fehlende/übergroße Probe blockiert
  konservativ; der Mail-Leseversuch allein bestätigt den Kopia-Kindprozess nicht.
- Login-Keychain-ACL bei Ad-hoc-Updates ist unbestätigt; keine Entitlement-/Team-/Datei-Ausnahme.
- Kopia 0.23.1: Server-Checkpoints derzeit 45 statt gewünschter 15 Minuten; nicht durch Architekturumbau kaschieren.
- Restore-Metadatenlimits: xattrs/ACL/Finder-Tags/Ressourcen-Fork im getesteten Standardworkflow unvollständig;
  Details in Metadaten-Fixtures und historischem Plan-/Statusarchiv.
- S3/WebDAV haben umfangreiche isolierte Spikes; vollständige Swift-/Agent-/UI-Integration und SFTP offen.
- Systemfreigaben/Installation/Updates auf echten Macs müssen am fertigen Pfad nachgewiesen werden.

## Pflege nach einem Auftrag

Aktuelle Verdrahtung und Einstiegspunkte hier ersetzen, nicht neue Tagesprotokolle anhängen.
Nachweise mit Codezustand/Toolchain und nächster ausführbarer Auftrag stehen kompakt in STATUS.md.
Nur geänderte normative Verträge und Architekturentscheidungen in PROJEKT.md aktualisieren.
Aktueller Live-/Prüfstand: STATUS.md; Einstiegsevidenz: [Phase-1-Einstieg](history/STATUS-Phase1-Einstieg-2026-10-25.md).
Archiv nur bei einer konkreten Frage lesen: [historischer Status](history/STATUS-2026-10-25.md),
[abgelöster Plan](history/PLAN-bis-2026-10-25.md).
