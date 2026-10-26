# Implementierungsatlas

Stand: 2026-10-26. Kompakter Codeatlas, keine Sessionchronik.
Normative Architektur: PROJEKT.md; aktiver Auftrag und Nachweise: STATUS.md.
Alte Phasen-/Batch-Nummern in Kommentaren und Protokollen sind historische Referenzen.

## Plattform und Architektur

- Nur macOS 27.x, natives arm64. Deployment Target 27.0 in Config/Shared.xcconfig und MacKopiaKit/Package.swift.
- Stabile Toolchain: aktuell Xcode 27.1 / Swift-Compiler 6.4 / Sprachmodus Swift 6 / SDK 27.
- SwiftUI/Observation/MainActor für UI-State; cancellable Actors/strukturierte Concurrency in Package und Dienst.
- App → AgentProtocol/XPC → Agent → BackupEngine → KopiaCLI/KopiaServer; keine Kopia-Imports in App.
- `AgentAppDelegate` besitzt einen `LocalBackupService`, dieser genau eine `AutomaticBackupRuntime`.
  Setup, manuelle/automatische Läufe und serielle Nacharbeit teilen Gate, Config/History, Keychain und Laufwerksschutz.
- `LocalServiceMutations` sperrt Queue/Admission; UUID-Steuersperren in JobQueue halten Folgeläufe bis zum Cleanup.
  `ServiceClock` ermöglicht virtuelle Terminierung bei separat injizierbarem Prozess-/Fortschrittstakt.
- Ad-hoc-Signaturen ohne Apple-Konto, aktive Hardened Runtime, keine zusätzlichen Entitlements.
- Xcode-Debug-Dylib deaktiviert; Produkttests außerhalb der App, ohne gelockerte Library Validation.

## Vorhandene Bausteine und Integrationsgrenzen

| Bereich | Implementiert / relevante Einstiegsstellen | Noch zu verbinden |
|---|---|---|
| Domain | BackupDomain: validierte Quellen/Ziele/Pläne, UUID-Identität, Policies, Lauf-/Prüfergebnisse | Version-6-Requests tragen validierte Domain-Auswahl einschließlich Volume-UUID |
| CLI | KopiaCLI: isolierte Prozesse, Whitelist-Umgebung, Timeout/Cancel/Reaping, begrenzte Pipes, Bootstrap/Binding, Verify, Restore-Stichprobe, Wartung lesen/ausführen | Dateisystem, S3 und WebDAV im Dienst verdrahtet; SFTP folgt |
| Server | KopiaServer: loopback TLS, Zertifikatspin, Auth/CSRF, REST, Shutdown/Abbruch | KopiaRestoreServing/ServerRestore: Manifest-/Namensrestore, Task-Zähler/Abbruch und Nutzer-Pin/Beschreibung verdrahtet |
| Konfiguration | Persistence/ConfigStore: atomare Konfiguration, Live-Reload-Grundlage | Dienstbesitz, validierte Mutationen und explizite Recovery über XPC verdrahtet |
| Historie | Persistence/HistoryStore + VerificationHistory: dauerhafte Läufe und artgetrennte Prüfnachweise | Läufe/Verify/Test-Restore plus append-only MaintenanceHistory; artgetrennte Evidenz über XPC/UI |
| Secrets | Secrets/AgentKeychainStore → KeychainStore(): Login-Keychain, SecItem, Standard-App-ACL, LAContext ohne UI; alter Team-Adapter nur Vertragsbestand | Echte Agent-Keychain-/Update-Abnahme offen; kein Datei-Fallback |
| Schutz | BackupPreflight, BackupOperationCoordinator, RepositoryOperationGate, SystemIntegration | Lokaler Dienst verwendet gemeinsames Gate/Schutz; AgentFullDiskAccessProbe verlangt frische Agent-/Kopia-Leseevidenz. Installierte TCC-Zuordnung offen |
| Manuelle Engine | ManualBackupEngine, ConfiguredJobRunner, FilesystemBackupSessions, Policy-Abgleich | LocalBackupService → XPC → AgentConnection/Übersicht/Menüleiste verdrahtet |
| Automatik | AutomaticBackupRuntime/Controls/State, Scheduler, Monitore, Retry/Pausen/Recovery/Historienabgleich | Als alleiniger Queue-/Engine-Besitzer verdrahtet; Pausen/Termine/Recovery und Live-Neustart über XPC/UI |
| Vertrauen | Health, Plausibilität/Pinning, SnapshotVerificationEngine, AutomaticSnapshotVerification, AutomaticTestRestore | PlanRuntimeState/PlanRuntimeView zeigen Health/Folgeaktionen und dauerhafte Prüfnachweise; AgentNotifications |
| Wartung | MaintenanceCoordinator, FilesystemMaintenanceInspection, KopiaMaintenanceReader/Runner | Frische Owner-/Terminprüfung, automatische serielle Nacharbeit und dauerhafte Ziel-Evidenz verdrahtet |
| XPC | AgentSigningIdentity, AgentServiceClient/Server, AgentWirePacket/Request, AgentServiceRegistration; Version 6, Grenzen/Korrelation, asynchrone Antworten, Revisionsbeobachtung/Reconnect | Echter registrierter positiver/negativer Peer-Test; weitere Requests in Folgephasen |
| UI | App/AgentConnection, LocalSetupStore/View, PlanEditorStore/View, FoundationView/Settings, PreviewData; Agent/AgentRuntimeStore und echte Menüleiste; DE/EN | RestoreStore/View/Sheet, SnapshotMetadataSheet, RestorePreviewData und RecoveryKit DE/EN verdrahtet; Live-Design-/A11y-/Druckabnahme offen |
| Restore | LocalServiceRestore/Utilities, RestoreBrowser/Destination, RestoreState/SearchMatch | Gemeinsame Gate-/Runtime-Steuerung, Ziel-/Ausgabe-UUIDs, Snapshot-Abstammung, Abbruch/Fortschritt und Vorschau-Cleanup; kein Originalquellenzugriff |
| System | UUID-Monitore, DiskArbitration-Schutz, Network/Energie/Wake, SleepAssertion | Live-Berechtigungsnachweise und gebündelte UI-/A11y-/Performance-Abnahme |

## WebDAV-Pfad

- `WebDAVSetup`: begrenztes reflektionsgeschütztes One-way-Envelope; `LocalServiceWebDAVSetup` besitzt
  Create/Connect und vor Speicherung authentifizierten Credential-Ersatz. XPC 6, Agent-Dispatch und Assistent DE/EN.
- `KopiaWebDAVSetup`: Create-only über Environment, danach vollständige Konfiguration ausschließlich im Speicher;
  Connect nutzt Status/Format-Blob und Owner-Auswertung. Keine reguläre Connection und keine Config-Mutation.
- `RepositoryCredentials` liest Keychain frisch; CLI-Reader/Verify/Test-Restore/Wartung und `KopiaBackupSession`
  führen das Payload über vorhandene frische Pipe pro Spawn. `RemoteRepositoryAccess` prüft S3/WebDAV.
- Gemeinsamer Dienst/Runtime-/Restore-Schutz; Remote-Browser ohne Originalquelle braucht keinen Volume-Monitor.
  HTTP ausschließlich literales 127.0.0.1 im Test; Produktion HTTPS. Recovery-Kit ohne Credentials, Pipe-Hinweis.
- `WebDAVContractTests` und `WebDAVServiceIntegrationTests`: Grenzen/Envelope, Create/Connect/Backup/Restore,
  falsche Zugänge, Credential-Erhalt, fremder Owner, Offline-Ablehnung und Secret-Negativscan.

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

## Restore-/Recovery-Pfad

- AgentProtocol Version 6 trägt Snapshot-ID/Namenskomponenten; der Client kann keine rohen Kopia-Objekt-IDs wählen.
- LocalServiceRestore reserviert Automatiksteuerung/Gate bis Server-Shutdown/Reaping; liest frische Konfiguration,
  prüft Binary/isoliertes Binding/Keychain und schützt Speicherziel plus Ausgabevolume. Keine Originalquelle nötig.
- RestoreBrowser löst jede Auswahl aus frischen Manifesten/Verzeichnissen auf und übernimmt gespeicherte Namensbytes.
  NFC/NFD-Mehrdeutigkeit und Symlink-Abstieg blockieren. Fremde Benutzer-/Rechneridentitäten bleiben vollständig.
- Ausgabe: neuer privater UUID-Ordner unter gewähltem Elternordner; kein registriertes Speicherziel als Ausgabe.
  Overwrite-Schalter aus, Restored-SUCCESS nur ohne Skipped Files/Ignored Errors; Teilresultate bei Abbruch erhalten.
- Quick Look: Dateirestore bis 50 MB unter privater Cache-Sitzung; explizites Clear/Schließen und Shutdown löschen sie.
- App/RestoreStore besitzt Auswahl/Filter/Sortierung/Suche/Dialog; Views bleiben bei Systemkomponenten.
  RecoveryKit nutzt NSPrintOperation einschließlich PDF und enthält keine Passwörter; Angebot nach Einrichtung.

## S3-Pfad

- `S3Setup` ist eine begrenzte, reflektionsgeschützte XPC-Eingabe. Das gesamte Passwort-/AWS-Envelope liegt
  unter der bestehenden `Repository.secretRef` in genau einem Keychain-Item; die Konfiguration enthält nur Metadaten.
- `KopiaS3Setup`: `create --create-only`, danach atomare 0600-Verbindung ohne Credential-Felder, explizite
  Cache-Kapazitäten, Balanced/zstd und eigener Wartungs-Owner. Connect übernimmt fremde Owner unverändert.
- Der bestehende `KopiaFilesystemBinding` prüft jetzt zusätzlich S3: exakter Storage-Allowlist-Vergleich,
  stabile Identität, keine Actions, keine Credential-Felder. Dateisystem-Decodierung bleibt kompatibel.
- `RepositoryCredentials` lädt frisch; bestehende Session-/Verify-/Test-Restore-/Wartungsadapter reichen nur
  typisierte AWS-Environment-Werte an die bewährten CLI-/TLS-Prozesse weiter. Gemeinsame Runtime/Gates bleiben.
- `RemoteRepositoryAccess`/`KopiaRepositoryProbe`: Passwort/Status plus frischer Format-Blob-Read; lokaler Cache
  zählt nicht als Auth-Nachweis. Quelle/Volume/FDA gelten beim Backup, beim Restore nur die Ausgabe-Volumes.
- XPC 6: Setup und Credential-Aktualisierung; Ersatz vor Keychain-Write prüfen, bei Fehlschlag altes Item behalten.
  Assistent/Quelle, Destination-Liste, Credential-Sheet und Recovery-Kit sind DE/EN angebunden.
- `S3ServiceIntegrationTests`: temporäres SigV4-/Chunk-signaturprüfendes Loopback-S3, Create/Backup/Verify,
  Test-Restore, Neustart, fehlende Originalquelle, Vollrestore, Connect, falscher Schlüssel/Token/Passwort,
  Credential-Erhalt, Offline-Ablehnung und Secret-Negativscan. `S3ContractTests` prüft Grenzen/Bindings/XPC.

## Repräsentative Tests und Werkzeuge

- MacKopiaKit/Tests/FoundationTests/ManualBackupIntegrationTests.swift: echtes Temp-Ziel, zwei Quellen,
  Historie, Backup/Restore/Abbruch; VerifyIntegrationCheck ergänzt Prüfungen und echte fällige Full-Wartung.
- Automatic*Tests und DailyRuntimeTests: virtuelle Zeit/Ereignisse, Recovery, serielle Prüf-/Wartungsnacharbeit,
  Abbruch und Queue-Sperren. DailyServiceTests: Dienst-Neustart, persistente Pausen/Optionen/Fehler und Monitor-Recovery.
- BackupNotificationPolicyTests: Tageslimit, Uhr-Rückstellung, einmaliger erster Erfolg, stille Bedingungswartezeit.
  MaintenanceHistoryTests: Reopen, getrennte Ziel-Evidenz und kein Überschreiben über doppelte IDs.
- VolumeEjectionSafetyTests: tatsächlicher Volume-Mountpoint statt Ziel-Unterordner; falsche UUID und nicht abnehmbare Volumes werden vor nativen Schreibaktionen abgewiesen.
- AgentSigningIdentityTests.swift: echte temporäre Ad-hoc-Bundles, Manipulation/gleichnamiger fremder Code,
  Layout und laufender Eigenvergleich; keine permanente Dienstregistrierung.
- Tests/BundleLayoutTests.swift: gebautes Produkt, App-/Agent-/Kopia-Signaturen, Runtime und Plattformmetadaten.
- KopiaContractTests + Fixtures/kopia-0.23.1: bereinigte echte Kopia-Verträge.
- Scripts/tests: Download-Isolation, Architekturprüfung und Probe-Sicherheit; lange Scripts/spike-* nur bei Bedarf.
- LocalServiceIntegrationTests: echter temporärer Service-Lifecycle einschließlich Create/Connect, zusätzlichem
  Plan/Editor, manuellem und automatisch terminierten Run, 10-Prozent-Verify, Test-Restore, explizitem Verify,
  bytegleichem Restore, Reopen und Secret-Negativscan. LocalBackupServiceTests prüfen
  Safe Mode/Recovery, stale Volume-Auswahl und Cancellation; LocalServiceTransportTests echten nativen XPC-Peer.
- SchedulerTests.delayedTimerTaskRetainsTheOriginalMonotonicDeadline: Task-Start verzögert die Deadline nicht.
- RestoreServiceIntegrationTests: fremder Benutzer/Rechner, entfernte Originalquelle, Browser/Suche,
  SHA-256-Restore samt leerer Datei/Symlink/POSIX/mtime, bestehendes Ziel abgewiesen, Preview-Cache gelöscht,
  Abbruch und erneute Admission, Beschreibung/Pin/Unpin ohne Verlust von Sicherheits-Pins, Secret-Negativscan.
- RestoreBrowserTests/RestoreSelectionTests: Ancestry/Traversal/UUID/Symlink, Unicode-Namensbytes und
  Mehrdeutigkeit, begrenzte zyklische Suche/Cancellation und private eindeutige Ausgabeverzeichnisse.
- Config/kopia-version.json bleibt auf 0.23.1 gepinnt. Historischer amd64-Hash ist keine Supportzusage;
  der aktuelle Fetch-/Embed-Pfad verwendet ausschließlich arm64, ohne lipo-Universal-Erzeugung.

## Bekannte technische Grenzen

- Restore-Browser: maximal 128 Quellen/1.000 Snapshots/8 MiB, maximal 2.000 Einträge pro Verzeichnis;
  größere Bestände werden abgewiesen. Suche: 256 Verzeichnisse/10.000 Einträge/500 Treffer/Tiefe 64, sichtbare Grenze.
- Kein Überschreiben/Originalort-Restore freigegeben; neuer privater Ordner bleibt der sichere Standard.
- Live-Restore-/Quick-Look-Durchgang, Drucklayout/PDF und DE/EN-/A11y-Abnahme ausstehend.
- Nach hartem Dienstabbruch können private Quick-Look-Cache-Reste bleiben; regulärer Close/Shutdown löscht die Sitzung.

- Lokaler manueller Nutzerworkflow ist verdrahtet und temporär integriert geprüft; installierte
  SMAppService-/Keychain-/FDA-Abnahme konnte ohne Computer-Use-Freigabe nicht durchgeführt werden.
- Neue Pläne sind bis zur bewussten Terminwahl manuell. Editor: Intervall/täglich/Mount, Netzteil/Nachholen,
  optionales Auswerfen; komplexe/Wochentagstermine werden unverändert erhalten. Restore-UI einschließlich Quick Look und Recovery-Kit ist verdrahtet.
- Native Mitteilungszustellung und echtes Unmount-/Eject-Verhalten brauchen die separate Live-/Hardware-Abnahme.
  Keine Aussage über bereits durchgeführte Screenshots, VoiceOver oder registrierten Dienstbetrieb.
- FDA-Probe verlangt nichtleere reguläre Safari-Bookmarks ≤1 MiB. Fehlende/übergroße Probe blockiert
  konservativ; der Mail-Leseversuch allein bestätigt den Kopia-Kindprozess nicht.
- Login-Keychain-ACL bei Ad-hoc-Updates ist unbestätigt; keine Entitlement-/Team-/Datei-Ausnahme.
- Kopia 0.23.1: Server-Checkpoints derzeit 45 statt gewünschter 15 Minuten; nicht durch Architekturumbau kaschieren.
- Restore-Metadatenlimits: xattrs/ACL/Finder-Tags/Ressourcen-Fork im getesteten Standardworkflow unvollständig;
  Details in Metadaten-Fixtures und historischem Plan-/Statusarchiv.
- S3 und WebDAV sind im Dienst/Assistenten einschließlich Restore integriert; SFTP-Produktionsintegration offen.
- S3: HTTPS, HTTP nur für literales 127.0.0.1 im lokalen Fixture; Object-Lock-Einrichtung noch nicht freigegeben.
  Kein Nachweis eines realen Providers, produktiver IAM-Policies oder echten Keychain-Credential-Wechsels.
- Systemfreigaben/Installation/Updates auf echten Macs müssen am fertigen Pfad nachgewiesen werden.

## Pflege nach einem Auftrag

Aktuelle Verdrahtung und Einstiegspunkte hier ersetzen, nicht neue Tagesprotokolle anhängen.
Nachweise mit Codezustand/Toolchain und nächster ausführbarer Auftrag stehen kompakt in STATUS.md.
Nur geänderte normative Verträge und Architekturentscheidungen in PROJEKT.md aktualisieren.
Aktueller Live-/Prüfstand: STATUS.md; Phase-1-Abschluss: [Archiv](history/STATUS-Phase1-Abschluss-2026-10-25.md). Einstiegsevidenz: [Phase-1-Einstieg](history/STATUS-Phase1-Einstieg-2026-10-25.md).
Archiv nur bei einer konkreten Frage lesen: [historischer Status](history/STATUS-2026-10-25.md),
[abgelöster Plan](history/PLAN-bis-2026-10-25.md).
