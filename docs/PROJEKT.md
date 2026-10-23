# MacKopia – Projektbeschreibung & Umsetzungsleitfaden

> **Arbeitstitel:** MacKopia · **Status:** Spezifikation v1.0 · **Stand:** 2026-10-23
> **Zielgruppe dieses Dokuments:** Coding-Agents und Entwickler, die die App schrittweise umsetzen.
> Dieses Dokument ist die **verbindliche Quelle** für Architektur, Entscheidungen und Abnahmekriterien.
> Abweichungen werden hier dokumentiert (Abschnitt 17 „Entscheidungslog“), nicht stillschweigend im Code.

---

## 0. Kurzfassung

MacKopia ist eine native macOS-App (Swift 6.2, SwiftUI, macOS 26 Tahoe+), die [Kopia](https://kopia.io) als
Backup-Engine nutzt und daraus ein **Time-Machine-einfaches, Arq-zuverlässiges** Backup-Produkt macht:

- **Backup-Pläne**: Mehrere Pläne mit eigenen Quellen, Zielen, Zeitplänen, Aufbewahrungsregeln und Ausschlüssen.
- **Ziele**: Lokal/USB/Thunderbolt, NAS per SMB, SFTP, WebDAV, S3-kompatibel (AWS, B2, Wasabi, MinIO).
- **Automatik**: Zeitplan, „Laufwerk angeschlossen“, „NAS erreichbar“, mit Bedingungen (Netzteil, kein teures Netz).
- **Robust**: Hintergrund-Agent (läuft ohne geöffnetes Fenster), Selbstheilung, Vorabprüfungen, Integritätsprüfung.
- **Sicher**: Passwort ausschließlich im Schlüsselbund, verschlüsselte lokale Kopia-API mit Zertifikats-Pinning,
  signierte XPC-Kommunikation, Wiederherstellungs-Kit.
- **Wiederherstellen**: Finder-artiger Snapshot-Browser, Quick Look, Wiederherstellen einzelner Dateien oder ganzer Ordner.
- **Vertrieb**: Developer ID, notarisiert, Auto-Updates via Sparkle 2, Kopia-Binary im Bundle mitgeliefert.
- **Sprachen**: Deutsch (Primär) + Englisch über String Catalog.

---

## 1. Korrekturen & Präzisierungen gegenüber dem ursprünglichen Prompt

| Ursprüngliche Idee | Entscheidung | Begründung |
|---|---|---|
| macOS 15 „Golden Gate“ | **macOS 26 Tahoe als Mindestversion** (Entwicklung/Test auf macOS 27) | macOS 15 heißt „Sequoia“. macOS 26 bringt Liquid Glass, aktuelle SwiftUI-APIs und die neue Swift-XPC-API mit Peer-Requirements. |
| `/opt/homebrew/bin/kopia` nutzen | **Kopia im App-Bundle mitliefern** (`Contents/Helpers/kopia`), signiert und notarisiert, Version festgelegt | Reproduzierbar, kein Homebrew-Update kann die App zerstören, keine Abhängigkeit von der Installation. Eigener Pfad nur als „Experten“-Option. |
| Ein `BackupManager` als zentrales `@Observable` | **Schichtenarchitektur**: Engine im Agent (Actors), UI-State als kleine `@Observable`-Stores pro Feature | Ein Gott-Objekt skaliert nicht und ist nicht testbar. Backups müssen ohne UI laufen. |
| Nur `Process` + stdout parsen | **Hybrid**: privater `kopia server` (REST/JSON) für Snapshots, Fortschritt, Browsing, Restore; direkte CLI-Aufrufe mit `--json` für Einrichtung/Wartung | Strukturierter Fortschritt statt fragilem Text-Parsing (so macht es auch KopiaUI). |
| „Pause“ hält den Prozess an | **Pause = sauberer Abbruch mit Checkpoint; Fortsetzen = neuer Lauf, der dank Deduplizierung bereits Übertragenes überspringt** | Kopia kennt kein echtes Pausieren. `SIGSTOP` führt bei Netzwerkzielen zu Timeouts. Kopias inhaltsadressierter Speicher macht Neustarts billig. |
| „Stop ohne Datenkorruption“ | Abbruch über die Kopia-API (`sources/cancel`), Eskalation SIGINT → SIGTERM → SIGKILL nur als Notfall | Kopia schreibt Content-Blobs unveränderlich und das Snapshot-Manifest erst am Ende. Ein Abbruch korrumpiert das Repository nie, er hinterlässt höchstens einen „unvollständigen“ Snapshot. |
| Passwort-Feld mit Autofill (Enpass) | `SecureField` mit `.textContentType(.password)` bzw. `.newPassword`, Einfügen per ⌘V, Speicherung **nur im Schlüsselbund** | Funktioniert mit macOS-Passwörter-App und mit Enpass (Autofill/Einfügen). Passwort niemals in UserDefaults, Dateien, Logs oder argv. |
| Sandbox deaktivieren | **App Sandbox aus, Hardened Runtime an**, Festplattenvollzugriff (FDA) per Onboarding | Ohne Sandbox kein Mac App Store, deshalb Developer ID. Hardened Runtime ist für die Notarisierung Pflicht. |
| Laufwerk „im Hintergrund prüfen“ (Polling) | **Ereignisgesteuert**: `NSWorkspace`-Mount-Notifications + DiskArbitration, Identifikation über Volume-UUID | Kein Polling, keine Verwechslung bei gleichen Volume-Namen. |

---

## 2. Lehren aus führenden Backup-Lösungen (nicht das Rad neu erfinden)

| Vorbild | Übernommenes Prinzip | Umsetzung in MacKopia |
|---|---|---|
| **Time Machine** | Null-Konfiguration, „angesteckt = gesichert“, Status in der Menüleiste, Auswerfen blockieren während eines Backups | Onboarding mit sinnvollen Vorgaben; Trigger „Laufwerk verbunden“; DiskArbitration-Unmount-Approval; Menüleisten-Status mit „Letztes Backup: vor 12 Min.“ |
| **Arq** | Getrennter Hintergrund-Agent, Backup-Pläne, regelmäßige Validierung, E-Mail/Notification-Berichte, „Pause für 1 Stunde“, Wiederherstellungs-Kit | Agent via `SMAppService`; Plan-Modell; geplante `snapshot verify`-Läufe und Test-Restores; Pause mit Dauer; PDF-Recovery-Kit |
| **Backblaze** | Sorglos-Modus, sehr klare Warnungen („Seit 14 Tagen nicht gesichert“) | Gesundheitsampel pro Plan mit Schwellwerten und Mitteilungen |
| **Vorta (Borg-GUI)** | Profile, Keychain-Speicherung, Bedingungen (Netzteil, WLAN-Liste, keine teuren Netze), Pre-/Post-Skripte | Ausführungsbedingungen pro Plan; Hook-Skripte (Phase 2, optional) |
| **Backrest (restic-WebUI)** | Strikte Trennung **Repository ↔ Plan**, Operations-Log/Historie, Hooks, geplante Prune/Check-Läufe | Datenmodell `Repository` getrennt von `BackupPlan`; Aktivitätsverlauf in SQLite; Wartung zeitgesteuert |
| **Pika Backup (Borg-GNOME)** | Radikal einfache UI, Laufwerk über UUID, „Zeitplan mit Bedingungen“ | Wenige, klare Bildschirme; Expertenoptionen hinter „Erweitert“ |
| **KopiaUI** | Wrapping von `kopia server` mit TLS + Zufallspasswort + `--shutdown-on-stdin`; ein Config-File pro Repository | Gleiches Startprotokoll, aber nativ, mit Zertifikats-Pinning und Agent |
| **restic/Borg-Community** | Bekannte Fallen: verwaiste Locks, Hostname-Wechsel, leere Mountpunkte, iCloud-Platzhalterdateien | Abschnitt 9 „Vorabprüfungen & bekannte Fallen“ |

---

## 3. Produktumfang

### 3.1 Version 1.0 (Pflicht)

1. **Onboarding-Assistent** (erste Ausführung): Willkommen → Festplattenvollzugriff → Hintergrund-Agent erlauben → Ziel wählen/anlegen
   oder bestehendes Repository verbinden → Quellen wählen (Vorschlag: Benutzerordner mit macOS-Ausschlüssen) → Zeitplan →
   Passwort + Wiederherstellungs-Kit → erstes Backup starten.
2. **Speicherziele (Repositories)**: Anlegen, Verbinden, Bearbeiten, Trennen, Entfernen. Typen: Dateisystem (lokal/USB/SMB-Mount),
   SFTP, WebDAV, S3-kompatibel (inkl. B2 über S3-API). Import einer bestehenden Kopia-Konfiguration (`~/Library/Application Support/kopia/repository.config`).
3. **Backup-Pläne**: n Quellen (Ordner/Dateien per `NSOpenPanel`, Mehrfachauswahl, Drag & Drop aus dem Finder), ein Ziel,
   Trigger, Bedingungen, Aufbewahrung, Ausschlüsse, Kompression, Priorität.
4. **Steuerung**: Jetzt sichern, Pausieren (mit Dauer: 1 h / bis morgen / unbegrenzt), Fortsetzen, Stoppen – pro Plan und global.
5. **Live-Fortschritt**: Phase, Prozent (geschätzt), Bytes verarbeitet/hochgeladen, Dateien, Durchsatz, Restzeit, aktuelle Datei.
6. **Wiederherstellen**: Snapshot-Liste (Tabelle, filterbar), Finder-artiger Browser, Quick Look, Wiederherstellen von Auswahl an
   einen frei wählbaren Ort (Standard: neuer Ordner, niemals stilles Überschreiben), Fortschritt und Abbruch.
7. **Aufbewahrung & Ausschlüsse**: grafischer Editor, Presets, macOS-Standardausschlüsse, Übernahme der Time-Machine-Ausschlüsse.
8. **Prüfung & Berichte**: geplante Integritätsprüfung, Test-Restore, Wartung (quick/full), Gesundheitsstatus, Mitteilungen,
   Aktivitätsverlauf, Diagnose-Export.
9. **Menüleiste**: Status, letzter/nächster Lauf, Fortschritt, Schnellaktionen.
10. **Einstellungen**: Allgemein, Benachrichtigungen, Netzwerk & Energie, Erweitert (Kopia-Version, Logs, eigener Binary-Pfad).
11. **Updates** über Sparkle 2.

### 3.2 Bewusst NICHT in 1.0 (dokumentiert, Architektur vorbereitet)

- APFS-Snapshots als konsistente Quelle (benötigt privilegierten Helper für `mount_apfs -s`) → Phase 2.
- Pre-/Post-Hook-Skripte (Kopia-Actions) → Phase 2.
- Kopia-Repository-Server (Multi-User), Google Drive, Azure, rclone → bei Bedarf.
- Mount eines Snapshots im Finder (`/api/v1/mounts`, WebDAV) → Phase 2 (nice to have).
- iOS/iPadOS-Companion, Widgets, App Intents/Kurzbefehle → Phase 2 (App Intents sind jedoch einfach und empfohlen).

---

## 4. Technologie-Stack & Rahmenbedingungen

| Bereich | Festlegung |
|---|---|
| Sprache | Swift 6.2, **Strict Concurrency = complete**, Swift-6-Sprachmodus |
| UI | SwiftUI (macOS 26 SDK), AppKit nur gezielt (`NSOpenPanel`, `QLPreviewPanel`, `NSWorkspace`) |
| Isolation | App-Targets: `Default Actor Isolation = MainActor` (Approachable Concurrency). Pakete: nonisolated by default, explizite Actors |
| Mindest-OS | macOS 26.0, Universal Binary (arm64 + x86_64) |
| Build | Xcode 26+ Projekt mit App-Target + Agent-Target; **gesamte Logik in lokalem Swift Package** `MacKopiaKit` |
| Tests | Swift Testing (`@Test`, `#expect`), XCUITest für Smoke-Tests, Integrationstests gegen echtes Kopia |
| Persistenz | Konfiguration: versioniertes JSON (Codable, atomare Writes). Historie: SQLite via **GRDB** (Migrationen) |
| Logging | `os.Logger` (Subsystem `<bundle-id>`, Kategorien pro Modul), Kopia-Logs in eigenem Log-Verzeichnis |
| Abhängigkeiten | **Nur**: Sparkle 2, GRDB. Optional `swift-subprocess` (swiftlang), wenn ≥ 1.0 verfügbar; sonst eigener `Process`-Wrapper |
| Signierung | Developer ID Application, Hardened Runtime, Notarisierung via `notarytool`, Stapling |
| Lizenz Kopia | Apache 2.0 → `LICENSE`/`NOTICE` von Kopia im Bundle und im „Über“-Fenster |

**Bundle-IDs (Platzhalter, vor Phase 0 festlegen):**
- App: `com.example.MacKopia`
- Agent: `com.example.MacKopia.Agent`
- XPC-Mach-Service: `com.example.MacKopia.Agent.xpc`
- Keychain-Access-Group: `$(TeamID).com.example.MacKopia.shared`

---

## 5. Systemarchitektur

### 5.1 Prozessmodell

```
┌──────────────────────────────┐        XPC (Mach-Service,         ┌─────────────────────────────────────┐
│  MacKopia.app  (UI)          │  ◄──── Peer-Requirement: ──────►  │  MacKopia Agent.app  (LSUIElement)  │
│  • Hauptfenster (Setup,      │        same Team ID)              │  • Engine (Scheduler, Trigger,      │
│    Pläne, Restore, Verlauf)  │                                   │    Job-Queue, Preflight, Health)    │
│  • kann jederzeit beendet    │                                   │  • MenuBarExtra (Status, Aktionen)  │
│    werden                    │                                   │  • Mitteilungen                     │
└──────────────────────────────┘                                   │  • Besitzer aller Konfig & Secrets  │
                                                                   └──────────────┬──────────────────────┘
                                                                                  │ spawn (kein Shell)
                                       ┌──────────────────────────────────────────┼────────────────────┐
                                       ▼                                          ▼                    ▼
                       kopia server start (pro Repo,          kopia repository create/connect,   kopia maintenance …
                       on demand, 127.0.0.1:0, TLS,           policy set, snapshot verify …      (CLI, --json)
                       Zufallspasswort, --shutdown-on-stdin)
```

**Grundregeln:**
1. Der **Agent ist die einzige Instanz, die Kopia startet** und Konfiguration schreibt. Die UI ist ein Client.
   Dadurch keine Race Conditions zwischen zwei Prozessen, die dasselbe Repository bedienen.
2. Der Agent wird via `SMAppService.agent(plistName:)` registriert (LaunchAgent-Plist in `Contents/Library/LaunchAgents/`,
   `BundleProgram` → `Contents/Library/LoginItems/MacKopia Agent.app/Contents/MacOS/MacKopia Agent`).
   Plist-Schlüssel: `MachServices` (XPC), `KeepAlive = { SuccessfulExit = false }` (Neustart nach Absturz),
   `LimitLoadToSessionType = Aqua`, `ProcessType = Standard` (**nicht** `Background` – sonst drosselt macOS die I/O massiv),
   `AssociatedBundleIdentifiers = [App-Bundle-ID]` (damit Systemeinstellungen den Agent der App zuordnet).
3. Status `SMAppService.status == .requiresApproval` → UI zeigt Hinweis + Button `SMAppService.openSystemSettingsLoginItems()`.
4. Der Agent hostet das **MenuBarExtra** (SwiftUI `App` mit nur `MenuBarExtra`-Scene, Stil `.window`).
   So ist der Status immer sichtbar, wenn Backups möglich sind – unabhängig vom Hauptfenster.
5. **Ein Kopia-Server pro Repository, on demand**: wird gestartet, wenn ein Job das Repository braucht oder die UI es browst,
   und nach 10 Minuten Leerlauf beendet. Wechseldatenträger sind so kein Sonderfall.
6. Jedes Repository bekommt **eigene, isolierte Kopia-Pfade** (niemals die Standard-Config des Nutzers mitbenutzen):
   - Config: `~/Library/Application Support/MacKopia/Repositories/<repoUUID>/repository.config`
   - Cache:  `~/Library/Caches/MacKopia/<repoUUID>/` (`--cache-directory`)
   - Logs:   `~/Library/Logs/MacKopia/kopia/<repoUUID>/` (`--log-dir`)

### 5.2 Schichten & Module (Swift Package `MacKopiaKit`)

```
MacKopiaKit/
├── Package.swift
├── Sources/
│   ├── KopiaCLI/          # Prozess-Ausführung, Binary-Locator, CLI-Kommandos (typisiert), JSON-DTOs, Fehler-Mapping
│   ├── KopiaServer/       # Server-Lifecycle (Start/Handshake/Stop), REST-Client mit TLS-Pinning, API-DTOs
│   ├── BackupDomain/      # Reine Modelle: Repository, BackupPlan, Schedule, Trigger, Conditions, RetentionPolicy,
│   │                      #   ExcludeRules, JobRun, Health – Codable, Sendable, ohne Abhängigkeiten
│   ├── BackupEngine/      # Scheduler, TriggerMonitor (Volumes/Netzwerk/Energie), JobQueue, Preflight, HealthEvaluator,
│   │                      #   MaintenanceCoordinator, VerifyCoordinator, PolicyTranslator (Domain → Kopia-Policy)
│   ├── Persistence/       # ConfigStore (JSON, atomar, versioniert, Migration), HistoryStore (GRDB)
│   ├── Secrets/           # KeychainStore (Data-Protection-Keychain, Access Group), SecretRef
│   ├── SystemIntegration/ # VolumeMonitor (DiskArbitration/NSWorkspace), NetworkMonitor (NWPathMonitor),
│   │                      #   PowerMonitor (IOKit), SleepAssertion, FullDiskAccessProbe, SMBMounter (NetFS), Notifications
│   ├── AgentProtocol/     # XPC-Protokoll/Transport, Versionierung, appseitige SMAppService-Grenze
│   └── TestSupport/       # FakeKopia-Binary-Builder, temporäre Repos, Fixtures (nur Test-Targets)
└── Tests/
    ├── KopiaCLITests/ KopiaServerTests/ BackupDomainTests/ BackupEngineTests/ PersistenceTests/
    └── IntegrationTests/  # gegen das mitgelieferte echte Kopia, Dateisystem-Repo in Temp-Ordner
```

**Abhängigkeitsrichtung (streng, per Package-Targets erzwungen):**
`BackupDomain` ← `KopiaCLI` ← `KopiaServer` ← `BackupEngine` → `Persistence`, `Secrets`, `SystemIntegration`;
`AgentProtocol` hängt nur von `BackupDomain` ab. Die App hängt nur von `AgentProtocol` + `BackupDomain` ab
(**die UI importiert niemals `KopiaCLI`/`KopiaServer`**).

### 5.3 Xcode-Projektstruktur

```
mackopia/
├── docs/PROJEKT.md                     # dieses Dokument
├── MacKopia.xcodeproj
├── MacKopiaKit/                         # lokales Swift Package (siehe 5.2)
├── App/                                 # Target "MacKopia" (UI)
│   ├── MacKopiaApp.swift                # @main, WindowGroup + Settings-Scene, Commands
│   ├── AgentClient/                     # XPC-Client, @Observable Stores, Event-Stream
│   ├── Features/
│   │   ├── Onboarding/
│   │   ├── Overview/                    # Dashboard
│   │   ├── Plans/                       # Liste, Editor (Quellen, Ziel, Zeitplan, Bedingungen, Aufbewahrung, Ausschlüsse)
│   │   ├── Repositories/                # Liste, Anlege-/Verbinde-Assistent je Typ
│   │   ├── Restore/                     # Snapshot-Tabelle, Browser, Quick Look, Restore-Sheet
│   │   ├── Activity/                    # Verlauf, Lauf-Details, Fehlerlisten
│   │   └── Settings/
│   ├── Components/                      # wiederverwendbare Views (StatusBadge, ByteCountText, ProgressPanel …)
│   ├── Resources/Localizable.xcstrings, Assets.xcassets
│   └── MacKopia.entitlements
├── Agent/                               # Target "MacKopia Agent"
│   ├── AgentApp.swift                   # @main, MenuBarExtra, startet Engine + XPC-Listener
│   ├── XPCServer/                       # Listener, Peer-Prüfung, Request-Routing
│   ├── MenuBar/
│   ├── LaunchAgent/Agent.plist            # Build-Template; Name/Identitäten aus App-Bundle-ID
│   └── Agent.entitlements
├── Scripts/
│   ├── fetch-kopia.sh                   # lädt gepinnte Kopia-Version, prüft SHA256, erzeugt Universal Binary (lipo)
│   ├── sign-and-notarize.sh
│   └── make-appcast.sh
├── Config/
│   ├── kopia-version.json               # { "version": "0.23.1", "sha256": { "arm64": "…", "amd64": "…" } }
│   ├── Shared.xcconfig, Debug.xcconfig, Release.xcconfig
└── .github/workflows/ci.yml
```

Bundle-Layout der fertigen App:
```
MacKopia.app/Contents/
├── MacOS/MacKopia
├── Helpers/kopia                                  # signiert, Hardened Runtime, gleiche Team-ID
├── Library/LoginItems/MacKopia Agent.app
├── Library/LaunchAgents/com.example.MacKopia.Agent.plist
├── Frameworks/Sparkle.framework
└── Resources/Licenses/kopia-LICENSE, kopia-NOTICE
```

---

## 6. Kopia-Integration (Kern – sehr präzise umsetzen)

### 6.1 Binary-Verwaltung

- `KopiaBinaryLocator` liefert standardmäßig `Bundle.main` → `Contents/Helpers/kopia`. Der Agent liegt in einem verschachtelten
  Bundle: Pfad über das Eltern-Bundle auflösen (`../../../../Helpers/kopia`) und mit `FileManager.fileExists` + Ausführungsrecht prüfen.
- Beim Agent-Start: `kopia --version` ausführen, Version gegen `kopia-version.json` prüfen. Abweichung → Health-Fehler
  „Kopia-Version unerwartet“ (bei eigenem Pfad nur Warnung).
- `Scripts/fetch-kopia.sh` (Build-Phase, gecacht): lädt die offiziellen Release-Archive für `darwin-arm64` und `darwin-x64`
  von GitHub, **verifiziert SHA256 gegen die gepinnten Werte**, erzeugt mit `lipo -create` ein Universal Binary
  und signiert bei explizit aktivierter Signierung mit `codesign --options runtime --timestamp`. Lokale Entwicklung
  derzeit mit `CODE_SIGNING_ALLOWED=NO`, ohne explizite Codesign-Aufrufe. Ohne passenden Hash bricht der Build ab.
- Kopia-Updates sind ein bewusster Vorgang: Version in `kopia-version.json` anheben → Integrationstests → Release.
- **Niemals** automatisch `kopia repository upgrade` ausführen. Ein Formatupgrade verlangt eine ausdrückliche Bestätigung des Nutzers mit Warnhinweis.

### 6.2 Prozessausführung (`KopiaProcess` – Actor)

Pflichtanforderungen:
1. **Kein Shell** (`/bin/sh -c` verboten). Argumente als Array. Quellpfade nie interpolieren.
2. **Explizite Umgebung**: Nur eine Whitelist erben (`HOME`, `USER`, `LANG=en_US.UTF-8`, `TMPDIR`). Setzen:
   `KOPIA_CHECK_FOR_UPDATES=false`, `KOPIA_PASSWORD` (nur wenn nötig), `KOPIA_LOG_DIR`, `KOPIA_CACHE_DIRECTORY`.
   Englische Locale erzwingen, weil Fehler-Mapping auf englischen Meldungen basiert.
3. **Passwörter nie in argv** (für alle Nutzer per `ps` sichtbar). Repository-Passwort über `KOPIA_PASSWORD` in der Umgebung des
   Kindprozesses. S3-Secrets über AWS-Umgebungsvariablen bei vollständig fehlenden Credential-Feldern in der
   Konfiguration. WebDAV: Credentials aus dem Schlüsselbund ausschließlich in eine im Speicher erzeugte
   JSON-Laufzeitkonfiguration einsetzen und über eine explizit vererbte anonyme Pipe übergeben. Frische Pipe pro
   Prozess, geschütztes 0500-Symlink-Verzeichnis und gemeinsame nicht geheime 0600-Wartungssperre; Deskriptoren
   und Laufzeitverzeichnis aufräumen. stdin bleibt für Shutdown frei. Keine secret-haltige reguläre Config-/Temp-Datei.
   Kopia-Konfigurations-Schreiboperationen sind bei diesem Transport ausgeschlossen; Änderungen verwaltet der Agent
   und übernimmt sie beim nächsten Prozessstart. SFTP-Zuführung noch offen (`KOPIA_SFTP_PASSWORD` nicht unterstützt).
4. **stdout und stderr gleichzeitig lesen** (zwei Tasks, `FileHandle.bytes` bzw. `AsyncSequence`). Sonst Deadlock bei vollem
   64-KB-Pipe-Puffer. stdout für JSON, stderr zeilenweise für Logs und den Server-Handshake.
5. **Immer `--config-file`, `--log-dir`, `--no-progress`** (wo unterstützt). Kopia 0.23.1 akzeptiert
   `--cache-directory` bei `repository create/connect` und `server start`, aber nicht global: dort explizit setzen. Danach den gespeicherten Cache-Pfad
   aus der isolierten Config verwenden und bei jedem Kindprozess `KOPIA_CACHE_DIRECTORY` setzen.
   Bei JSON-fähigen Kommandos `--json`.
6. **Timeouts** pro Kommando (z. B. connect 60 s, list 120 s, maintenance unbegrenzt mit Heartbeat). Überschreitung → Abbruch.
7. **Abbruch-Eskalation**: Swift-Task-Cancellation → `SIGINT` → 10 s → `SIGTERM` → 10 s → `SIGKILL`. Danach Zustand protokollieren.
8. **Kindprozess-Hygiene**: eigene Prozessgruppe; PID-Datei pro Repository-Server; beim Agent-Start verwaiste
   `kopia`-Prozesse aus PID-Dateien beenden (nur wenn PID + Executable-Pfad passen).
9. Exit-Code ≠ 0 → `KopiaError` mit `exitCode`, letzten 50 stderr-Zeilen (redigiert) und gemapptem `kind`.

### 6.3 Typisierte CLI-Kommandos (`KopiaCommand`)

Jedes Kommando ist ein Wert-Typ, der `arguments`, `environment`, `timeout` und den Ergebnis-Typ kennt:

| Zweck | Kommando (vereinfacht) |
|---|---|
| Repo existiert? | `repository connect <backend> … --readonly` testweise bzw. `/api/v1/repo/exists` (Server) |
| Repo anlegen | `repository create <filesystem\|sftp\|webdav\|s3> … --description=… --override-hostname=… --override-username=…` |
| Repo verbinden | `repository connect <backend> … --override-hostname=… --override-username=…` |
| Status | `repository status --json` |
| Trennen | `repository disconnect` |
| Policy setzen | `policy set <pfad> --keep-latest … --add-ignore … --compression=zstd …` (oder via `/api/v1/policy`) |
| Policy lesen | `policy show <pfad> --json` |
| Snapshots | `snapshot list <pfad> --json --all` |
| Prüfung | `snapshot verify --verify-files-percent=<n> --parallel=<n> [--json]` |
| Wartung | `maintenance info --json`, `maintenance set --owner=me`, `maintenance run [--full]` |
| Passwort ändern | `repository change-password` (Passwort via Umgebung, Spike!) |

Wichtig:
- **`--override-hostname` und `--override-username` beim Anlegen/Verbinden immer setzen** auf stabile Werte, die einmal beim
  Onboarding festgelegt werden (Standard: bereinigter `Host.current().localizedName` + Benutzerkurzname).
  macOS ändert Hostnamen bei Netzwerkkonflikten („MacBook-Pro-2“). Ohne Override „verliert“ Kopia sonst die Snapshot-Historie.
- **Wartungs-Owner**: Nach dem Anlegen bzw. Verbinden `maintenance info --json` lesen. Ist kein Owner gesetzt oder ist er
  `<user>@<override-host>`, dann `maintenance set --owner=me`. Gehört er einem anderen Rechner, Hinweis anzeigen und keine Wartung
  erzwingen (sonst Konflikte auf geteilten Repos).
- Repos, die nicht vom eigenen Rechner verwaltet werden, behandeln wir standardmäßig **nur lesend für fremde Quellen**
  (nur Restore, keine Löschung fremder Snapshots).

### 6.4 Kopia-Server: Lebenszyklus & Sicherheit

Startkommando (Agent, pro Repository):
```
kopia server start
  --config-file=<repoDir>/repository.config
  --log-dir=… --cache-directory=…           # Flag hier im server-start-Kontext zulässig
  --address=127.0.0.1:0                      # zufälliger freier Port, nur Loopback
  --tls-generate-cert                        # Ad-hoc-Zertifikat; Fingerprint wird gepinnt
  --tls-generate-cert-valid-days=365         # macOS lehnt den 3650-Tage-Standard ab
  --tls-generate-rsa-key-size=2048
  --tls-print-server-cert                    # Base64-PEM zum Aufbau des gepinnten TLS-Vertrauens
  --random-password                          # Basic-Auth-Passwort, nur im Speicher
  --random-server-control-password
  --server-username=mackopia
  --shutdown-on-stdin                        # Server beendet sich, wenn der Agent stirbt (stdin-EOF)
  --ui --no-grpc --control-api               # REST-UI-API benötigt --ui; kein Browser wird geöffnet
  --no-check-for-updates
  --no-async-repo-connect                    # Bool-Parser akzeptiert nicht --async-repo-connect=false
```
Mit `KOPIA_PASSWORD` in der Umgebung. Die Flags `--tls-generate-cert`, `--random-password`, `--random-server-control-password`,
`--shutdown-on-stdin` und `--tls-print-server-cert` sind in 0.23.1 versteckt, aber vorhanden (KopiaUI nutzt sie).

**Handshake**: stderr zeilenweise lesen und diese Präfixe parsen (exakt im Spike verifizieren):
- `SERVER ADDRESS: https://127.0.0.1:<port>`
- `SERVER CERT SHA256: <hex>`
- `SERVER CERTIFICATE: <base64-kodiertes PEM>` (nur mit `--tls-print-server-cert`)
- `SERVER PASSWORD: <pw>`
- `SERVER CONTROL PASSWORD: <pw>`
- `NOTIFICATION: …` (Kopia-interne Benachrichtigungen, ins Log)

Diese Werte niemals loggen (Logger-Privacy `.private`, stderr-Logging filtert diese Zeilen heraus).
Timeout für den Handshake: 30 s, danach Prozess beenden → `KopiaError.serverStartFailed`.

**REST-Client (`KopiaServerClient`, Actor)**:
- `URLSession` mit eigenem Delegate: Bei `NSURLAuthenticationMethodServerTrust` nur akzeptieren, wenn der
  **SHA256 des Leaf-Zertifikats** exakt dem gepinnten Fingerprint entspricht. Sonst ablehnen. Keine globale TLS-Lockerung, keine ATS-Ausnahmen.
- Basic-Auth-Header für die API (`mackopia:<password>`), Control-API mit `server-control:<controlPassword>`.
- Ephemere Session (`URLSessionConfiguration.ephemeral`), kein persistenter Cookie-/Cache-Speicher.
- **CSRF bleibt aktiv:** nach Prüfung des Zertifikat-Pins authentifiziert `GET /` aufrufen. Aus der Antwort ausschließlich
  `Kopia-Session-Cookie` und das Meta-Feld `kopia-csrf-token` im Arbeitsspeicher halten; UI-API-Anfragen senden Cookie
  und `X-Kopia-Csrf-Token`. Kopia 0.23.1 verlangt das Paar auch bei GET. Control-API nutzt separate Basic-Auth ohne CSRF.
- `--ui` aktiviert neben den HTML-Dateien auch die REST-UI-API; `--no-ui` liefert für die benötigten UI-API-Routen 404.
  Es wird kein Webbrowser geöffnet, und der Server bleibt ausschließlich über Loopback/TLS/Zufallszugangsdaten erreichbar.
- Alle DTOs **tolerant dekodieren** (Optionals, unbekannte Felder ignorieren). Die Kopia-API ist nicht offiziell versioniert.
  Contract-Tests gegen die gepinnte Version fangen Brüche ab.

**Verwendete Endpunkte** (in 0.23.1 vorhanden, Payloads im Spike mit echten Antworten als Fixtures festhalten):

| Endpunkt | Nutzung |
|---|---|
| `GET /api/v1/repo/status` | Verbunden? Beschreibung, Formatversion |
| `GET /api/v1/sources` | Quellen inkl. Upload-Status und Live-Zählern → **Fortschritt** |
| `POST /api/v1/sources/upload?userName=&host=&path=` | Snapshot einer Quelle starten |
| `POST /api/v1/sources/cancel?userName=&host=&path=` | Snapshot sauber abbrechen (Checkpoint) |
| `GET /api/v1/snapshots?userName=&host=&path=` | Snapshots einer Quelle |
| `POST /api/v1/snapshots/delete`, `/edit` | Löschen (mit Bestätigung), Beschreibung/Pin bearbeiten |
| `GET /api/v1/objects/{oid}` | Verzeichnisinhalt (JSON) bzw. Dateiinhalt (Quick Look, Einzeldatei-Download) |
| `POST /api/v1/restore` | Restore als Task; `options.restoreDirEntryAtDepth = 2147483647` für vollständigen Restore (sonst Platzhalter), alle `fsOutput.overwrite*` explizit aus |
| `GET /api/v1/tasks`, `/tasks/{id}`, `/tasks/{id}/logs`, `POST /tasks/{id}/cancel` | Restore-/Wartungs-Tasks, Fortschritt, Abbruch |
| `GET/PUT /api/v1/policy`, `POST /api/v1/policy/resolve` | Policies lesen/schreiben, effektive Policy anzeigen |
| `POST /api/v1/estimate` | Größe/Dateianzahl vor dem ersten Backup schätzen (Fortschritts-Prozent) |
| `PUT /api/v1/repo/throttle` | Bandbreitenlimit zur Laufzeit (Option „Netzwerk schonen“) |
| `POST /api/v1/control/shutdown` | Server sauber beenden (zusätzlich zu stdin-Schließen) |

**Scheduling in Kopia deaktivieren**: MacKopia ist die einzige Instanz, die Zeitpläne steuert. Kopia-Policies bekommen
**keine** `scheduling`-Einstellungen, damit nichts doppelt läuft. Wartung führt der Server automatisch aus, solange er läuft und
der Rechner Owner ist. Zusätzlich stößt der `MaintenanceCoordinator` sie gezielt an (siehe 7.6), weil Server bei
Wechseldatenträgern nur kurz laufen.

### 6.5 Fortschritt

- Polling von `GET /api/v1/sources` alle 1 s während eines Laufs (nur aktive Quelle), Werte in `BackupProgress` mappen:
  `hashedBytes/Files`, `cachedBytes/Files` (unverändert), `uploadedBytes`, `estimatedBytes/Files`, `directory` (aktueller Ordner),
  `errors/ignoredErrors`. Exakte Feldnamen aus Fixtures. `uploadedBytes` kann während aktiver Verarbeitung noch 0 sein;
  diesen Zähler nicht als Voraussetzung für Abbruch oder Aktivitätsstatus verwenden.
  In abgeschlossenen Manifesten zählt `stats.fileCount` in 0.23.1 die verarbeiteten Dateien ohne `cachedFiles`;
  die vollständige Dateizahl steht in `rootEntry.summ.files`.
- **Prozent** = (hashed + cached) / estimated. Wenn `estimated` fehlt: unbestimmter Fortschritt + Byte-Zähler.
  Vor dem ersten Lauf optional `/api/v1/estimate`.
- **Durchsatz/Restzeit**: gleitender Mittelwert (EWMA, α = 0.2) über die letzten 30 s; Restzeit erst nach 15 s anzeigen.
- UI-Updates höchstens 4×/s (throttle im Store). Die Events gehen per XPC-Stream an die UI.

### 6.6 Pause / Fortsetzen / Stopp – exakte Semantik

| Aktion | Verhalten |
|---|---|
| **Pausieren** (Plan) | Laufender Snapshot: `sources/cancel` → Kopia speichert Checkpoint bzw. unvollständigen Snapshot. Plan-Status `paused(until:)`. Trigger werden ignoriert, bis die Pause endet. UI-Text: „Pausiert – bereits gesicherte Daten bleiben erhalten.“ |
| **Pausieren** (global) | Wie oben für alle Pläne plus Warteschlange anhalten. Dauern: 1 Std., bis morgen 8:00, unbegrenzt. |
| **Fortsetzen** | Pause aufheben. War ein Lauf unterbrochen, sofort neu einreihen. UI: „Wird fortgesetzt – bereits übertragene Daten werden übersprungen.“ |
| **Stoppen** | Laufenden Snapshot abbrechen (wie Pause), aber **keine** automatische Wiederaufnahme. Nächster regulärer Trigger gilt wieder. Restliche Quellen des Plans in diesem Lauf werden übersprungen. |
| **Abbruch hängt** | Nach 30 s ohne Statuswechsel: Server-Prozess beenden (Eskalation 6.2/7), Lauf als `cancelled` mit Hinweis protokollieren. Kein Repo-Schaden möglich. |

Checkpoint-Ziel bleibt 15 Min.; Kopia 0.23.1 bietet dafür jedoch **kein Policy-Feld und keine Server-Option**.
Das versteckte CLI-Flag `snapshot create --checkpoint-interval=15m` wird akzeptiert (Obergrenze laut Quellcode 45 Min.).
Der unveränderte Server verwendet den Standard von 45 Min.; die 15-Minuten-Vorgabe ist im Serverbetrieb noch offen.
Ein sauberer API-Abbruch speichert unabhängig davon einen unvollständigen Snapshot mit `incomplete: "canceled"`.
Spike B prüft dessen Wiederverwendung nach einem Server-Neustart und einen vollständigen, bytegleichen Restore.
Der Abbruch kann bis zum Abschluss ausstehender Schreibvorgänge dauern; `sources/cancel` bestätigt nur die Anforderung,
nicht den bereits abgeschlossenen Abbruch. Erst Quellstatus `IDLE` und gespeicherten Snapshot auswerten.

---

## 7. Backup-Engine (Agent)

### 7.1 Domänenmodell (`BackupDomain`, alles `Codable & Sendable & Hashable`)

```swift
struct Repository: Identifiable { id: UUID; name: String; kind: RepositoryKind; createdAt: Date
                                  identity: SnapshotIdentity /* overrideUser, overrideHost */
                                  secretRef: SecretRef      /* Schlüsselbund-Referenz, nie das Secret */ }

enum RepositoryKind {
  case filesystem(path: String, volume: VolumeIdentity?)       // lokal, USB, SMB-Mount
  case sftp(host: String, port: Int, user: String, path: String, knownHostsFingerprint: String, auth: SFTPAuth)
  case webdav(url: URL)
  case s3(endpoint: String, bucket: String, prefix: String, region: String?, objectLock: Bool)
}

enum SFTPAuth {
  case password(secretRef: SecretRef)
  case privateKey(secretRef: SecretRef, passphraseRef: SecretRef?)
}

struct VolumeIdentity { uuid: String; name: String; isRemovable: Bool; isNetwork: Bool
                        remountURL: URL? /* smb://… aus URLResourceKey.volumeURLForRemountingKey */ }

struct BackupPlan: Identifiable { id: UUID; name: String; isEnabled: Bool; repositoryID: UUID
                                  sources: [BackupSource]; triggers: [Trigger]; conditions: RunConditions
                                  retention: RetentionPolicy; excludes: ExcludeRules; options: PlanOptions
                                  health: HealthThresholds }

struct BackupSource { id: UUID; path: String; volume: VolumeIdentity; bookmark: Data? }

enum Trigger { case interval(minutes: Int)                 // z. B. stündlich
               case daily(hour: Int, minute: Int, weekdays: Set<Weekday>)
               case onVolumeMount                          // Ziel- oder Quellvolume erscheint
               case onNetworkReachable                     // Ziel (NAS/SFTP/S3) wird erreichbar
               case manual }

struct RunConditions { requiresACPower: Bool; minBatteryPercent: Int?; skipOnExpensiveNetwork: Bool
                       skipOnConstrainedNetwork: Bool; allowedWiFiSSIDs: [String]? /* Phase 2 */
                       catchUpMissedRuns: Bool /* Standard true */ }

struct RetentionPolicy { keepLatest, keepHourly, keepDaily, keepWeekly, keepMonthly, keepAnnual: Int?; preset: RetentionPreset }
struct ExcludeRules { useMacOSDefaults: Bool; honorTimeMachineExclusions: Bool; ignoreCacheDirs: Bool
                      patterns: [String] /* gitignore-Syntax wie .kopiaignore */; maxFileSizeMB: Int?; oneFileSystem: Bool }
struct PlanOptions { compression: Compression /* .zstd (Standard), .s2, .none */; parallelism: Int?
                     lowPriority: Bool; uploadLimitMbps: Double?; ejectVolumeAfterBackup: Bool }
struct HealthThresholds { warnAfter: Duration /* Standard 3 Tage */; criticalAfter: Duration /* 7 Tage */ }
```

**Kopia-Quelle eines Plans** = jeder `BackupSource.path` ist eine eigene Kopia-Quelle (`user@host:path`). Ein Plan-Lauf
verarbeitet seine Quellen **sequenziell** (schonend für I/O, klarer Fortschritt). Unterschiedliche Repositories dürfen
parallel laufen (Limit konfigurierbar, Standard 1 global → vorhersehbar, Akku-schonend).

Speicherziel-Metadaten werden bei Initialisierung, Decoding und Encoding validiert. WebDAV-/S3-Endpunkte
enthalten keine URL-Zugangsdaten, Query oder Fragmente; HTTP/HTTPS bleiben für konfigurierte Ziele zulässig.
SFTP speichert ausschließlich Schlüsselbund-Referenzen für Passwort bzw. privaten Schlüssel und optionale Passphrase,
sowie einen bestätigten SHA256-Host-Key-Fingerprint im OpenSSH-Format. Das Modell selbst bestätigt keinen Host-Key
und implementiert noch keinen Secret-Transport. WebDAV-/S3-Backend-Zugangsdaten und deren Zuordnung zu
Schlüsselbund-Referenzen werden mit der späteren Engine-Anbindung ergänzt; `Repository.secretRef` bezeichnet das Backup-Passwort.
Ein Dateisystem-Ziel ohne gebundene Volume-Identität ist lediglich vorbereitete Konfiguration und darf nicht geöffnet werden.

**Policy-Übersetzung (`PolicyTranslator`)**: Retention, Excludes und Compression werden **pro Quelle** als Kopia-Policy
gesetzt (idempotent, vor jedem Lauf abgeglichen, wenn sich der Plan-Hash geändert hat). Gehören zwei Pläne zur gleichen
Quelle im selben Repo, ist das ein Validierungsfehler im Editor (sonst würden sich die Policies überschreiben).

Plan-Metadaten werden auch beim Decoding validiert: nichtleere Quellen-/Triggerlisten, eindeutige Quell-IDs
und wörtliche Quellpfade pro Plan, gültige Uhrzeiten/Wochentage, positive Intervalle und geordnete positive
Health-Schwellen. Health-Dauern werden verlustfrei als Sekunden-/Attosekunden-Paar gespeichert.
Benannte Aufbewahrungs-Presets müssen exakt §10 entsprechen; individuelle nichtnegative Werte einschließlich
nil/0 bleiben als „Eigene“ möglich. Das Modell führt keine Löschung oder Policy-Übertragung aus.
Numerische Prozess-/Byte-Konvertierungen müssen überlauffrei bleiben; nichtendliche Bandbreiten werden abgewiesen.
Konfigurationsgrenzen: 1024 Quellen und 64 Trigger pro Plan, 4096 einzeilige Ausschlussmuster mit je höchstens
16 KiB und zusammen 1 MiB; optionale WLAN-Namen höchstens 256 eindeutige Einträge à 32 UTF-8-Bytes.
WLAN-Bedingungen bleiben Metadaten für Phase 2 und werden noch nicht ausgewertet.

`PlanSetValidator` prüft den vollständigen vorgesehenen Konfigurationsstand vor dem Speichern: eindeutige
Plan-/Speicherziel-IDs, vorhandene Speicherziel-Referenzen und keine doppelte Kombination aus Speicherziel-ID
und wörtlichem Kopia-Quellpfad, auch bei deaktivierten Plänen oder abweichenden Volume-UUIDs. Ein Edit ersetzt
dabei den bisherigen Plan mit derselben UUID. Verschachtelte unterschiedliche Pfade bleiben eigenständige
Kopia-Quellen. Symlinks, tatsächliche Volumes und doppelt registrierte physische Speicherziele muss zusätzlich
die spätere Engine-Vorabprüfung behandeln; diese reine Modellprüfung ersetzt sie nicht.

### 7.2 Konfiguration & Migration

- `ConfigStore` (Actor) im Agent: Datei `~/Library/Application Support/MacKopia/config.json`
  mit `schemaVersion`, atomarer Write (geschützte temporäre Datei, fsync, rename im selben Verzeichnis),
  Backup der vorherigen Version (`config.json.bak`).
- Migrationen als geordnete Funktionen `vN → vN+1` mit Unit-Tests pro Schritt.
- Lesefehler → Agent startet im **Sicherheitsmodus** (keine Jobs), UI bietet „Backup der Konfiguration wiederherstellen“.
- Export/Import der Konfiguration (ohne Secrets) für Umzug auf einen neuen Mac.

Schema 1 enthält `schemaVersion` und `configuration` (validierte Speicherziele/Pläne, nur Secret-Referenzen).
Maximal 16 MiB pro Dokument, 1024 Speicherziele und 4096 Pläne. Unversionierte, beschädigte oder neuere
unbekannte Dokumente werden nicht als leere Konfiguration interpretiert. Fehlende Primärdatei ist nur dann
ein erster Start, wenn auch keine Sicherungskopie existiert. Laden liefert explizit Konfiguration oder
Sicherheitsmodus; normale Schreibzugriffe erfordern erfolgreiches Laden. Die Engine muss diesen Zustand
später vor Job-Freigabe auswerten; die Persistenzschicht selbst startet keine Jobs.

Speicherverzeichnis 0700, reguläre Dateien/Schreibsperre/temporäre Dateien 0600, Eigentümer aktueller Benutzer;
Symlinks und mehrfach verlinkte Dateien werden abgewiesen. Verzeichnisgebundene Dateideskriptoren und
`openat`/`renameat` halten Operationen am geprüften Verzeichnis. Eine nichtblockierende Dateisperre serialisiert
kooperierende Schreiber; ein Vergleich mit den zuletzt geladenen Bytes verhindert verlorene Änderungen
zwischen Store-Instanzen. Fehler nach begonnenem Schreiben sperren weitere normale Writes bis zum Neuladen.
Backup wird vor Primärdatei ersetzt, jeweils atomar. Ein Prozessabsturz kann eine geschützte temporäre Datei
hinterlassen; automatische Bereinigung solcher Altdateien ist noch nicht implementiert. Keine Garantie gegen
einen nichtkooperierenden Prozess mit denselben Benutzerrechten oder gegen Stromausfall aller Speichermedien.

Migrationen laufen ausschließlich vorwärts und müssen pro Schritt genau `vN → vN+1` liefern; danach erfolgt
vollständige Modellvalidierung. Laden migriert nur im Speicher, der nächste Save sichert die Originalbytes.
Aktuell existiert nur Schema 1, keine erfundene Vorgängermigration. Wiederherstellung ist ein separater,
explizit durch die Benutzeraktion aufzurufender Vorgang: Backup erst validieren, Primärdatei atomar ersetzen,
Backup unverändert behalten. Keine automatische Reparatur und keine automatische Freigabe von Jobs.
Export/Import sowie UI-/Agent-Anbindung folgen separat.

### 7.3 Scheduler

- Single Source of Truth: `Scheduler` (Actor) berechnet für jeden Plan `nextRunDate` aus den Triggern.
- Ein Timer auf das jeweils nächste Datum (`Task.sleep(until:)` mit `ContinuousClock` **plus** Neuberechnung bei
  `NSWorkspace.didWakeNotification`, Zeitzonen- und Uhrzeitänderung `NSSystemClockDidChange`), da Timer im Ruhezustand nicht feuern.
- **Nachholen** (anacron-Prinzip): Nach dem Aufwachen oder Agent-Start werden verpasste Läufe einmal nachgeholt
  (nicht n-fach), mit 2 Min. Verzögerung, damit Netzwerk und Volumes bereit sind.
- Jitter ±60 s für Intervall-Trigger, damit nicht alle Pläne gleichzeitig starten.
- Keine Läufe in den ersten 60 s nach dem Login (System kommt zur Ruhe).

### 7.4 Trigger-Monitore (`SystemIntegration`)

- **VolumeMonitor**: `NSWorkspace.didMountNotification`/`didUnmountNotification` + DiskArbitration (`DARegisterDiskAppearedCallback`)
  zur zuverlässigen UUID-Ermittlung (`URLResourceKey.volumeUUIDStringKey`, Fallback `kDADiskDescriptionVolumeUUIDKey`).
  Event → passende Pläne (Ziel- oder Quellvolume) → Trigger `onVolumeMount` mit 10 s Entprellung.
- **Unmount-Schutz**: Während ein Lauf auf ein Volume schreibt, `DARegisterDiskUnmountApprovalCallback` → Auswerfen
  mit Meldung „MacKopia sichert gerade auf dieses Laufwerk“ ablehnen, Mitteilung mit Button „Backup stoppen & auswerfen“ anbieten.
  Erzwungenes Auswerfen bzw. Kabel ziehen → Lauf `failed(.targetDisappeared)`, nächster Mount setzt fort.
- **Auswerfen nach Backup** (Option): `DADiskUnmount` + `DADiskEject` nach erfolgreichem Lauf.
- **SMB-Ziele**: Ist das Volume nicht gemountet, aber `remountURL` bekannt, mit `NetFSMountURLAsync` einbinden
  (Zugangsdaten liegen im Systemschlüsselbund, macOS-Standard). Ist der Server nicht erreichbar → `skipped(.targetUnavailable)`, ohne Fehler-Spam.
- **NetworkMonitor**: `NWPathMonitor` → `isExpensive`, `isConstrained`, Interface-Typ. Bei `onNetworkReachable` testet
  ein leichter Reachability-Check (TCP-Connect auf Host:Port, 5 s Timeout) das Ziel.
- **PowerMonitor**: `IOPSNotificationCreateRunLoopSource` + `IOPSCopyPowerSourcesInfo` (Netzteil, Ladestand),
  `ProcessInfo.isLowPowerModeEnabled` → bei Stromsparmodus Pläne mit `requiresACPower` überspringen.
- **SleepAssertion**: Während eines Laufs `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep, …)`
  mit Grund „MacKopia-Backup läuft“, garantiert freigegeben (defer / Actor-Deinit).

### 7.5 Job-Queue & Zustandsmaschine

```
            ┌────────┐ trigger  ┌─────────┐ preflight ok ┌─────────┐ alle Quellen ok ┌───────────┐
  idle ────►│ queued │─────────►│preflight│─────────────►│ running │────────────────►│ succeeded │
            └────────┘          └────┬────┘              └──┬───┬──┘                 └───────────┘
                                     │ Bedingung nicht        │   │ einzelne Dateifehler
                                     ▼ erfüllt                │   ▼
                                ┌─────────┐       pause/stop  │ ┌──────────────────────┐
                                │ skipped │◄──────────────────┘ │ succeededWithWarnings│
                                └─────────┘   ┌──────────┐      └──────────────────────┘
                                              │cancelled │   Fehler (Netz, Ziel weg, Kopia) ──► failed(reason) ──► retry?
                                              └──────────┘
```

- `JobQueue` ist ein Actor; ein Job = (Plan, Trigger, Zeitpunkt). Doppelte Jobs desselben Plans werden zusammengefasst.
- **Retry-Strategie** bei transienten Fehlern (Netzwerk, Timeout, Ziel kurz weg): exponentiell 1 → 5 → 15 Min.,
  max. 3 Versuche, danach `failed` + Mitteilung. Nicht-transiente Fehler (falsches Passwort, Repo nicht gefunden,
  Berechtigung) → sofort `failed`, kein Retry.
- Jeder Lauf erzeugt einen `JobRun`-Eintrag in der Historie (Start, Ende, Ergebnis, Statistik, Snapshot-IDs, Fehlerliste,
  Verweis auf Kopia-Logdatei).
- **Plausibilitätsprüfung nach dem Snapshot** („Ransomware-/Unfall-Wächter“): Fällt die Dateianzahl oder Gesamtgröße
  gegenüber dem vorherigen Snapshot derselben Quelle um > 50 % (konfigurierbar), Lauf als `succeededWithWarnings` markieren,
  den neuen Snapshot **pinnen** und eine kritische Mitteilung zeigen. Optional: Retention bis zur Bestätigung aussetzen.

### 7.6 Wartung & Prüfung

- **Wartung**: Kopia-Server führt Quick-/Full-Maintenance automatisch aus, wenn der Rechner Owner ist. Der `MaintenanceCoordinator`
  prüft nach jedem erfolgreichen Lauf `maintenance info --json` und startet fällige Full-Maintenance explizit
  (wichtig bei USB-Zielen, deren Server nur kurz läuft). Wartung niemals parallel zu einem Backup desselben Repos.
- **Verify** (Plan-Option, Standard: wöchentlich 1 % Stichprobe der Dateien, monatlich 10 %):
  `snapshot verify --verify-files-percent=<n>`. Ergebnis in Health und Historie.
- **Test-Restore** (monatlich, Standard an): zufällige Datei (< 50 MB) aus dem neuesten Snapshot in einen temporären Ordner
  wiederherstellen, SHA256 mit dem Original vergleichen (wenn unverändert laut mtime/size), Temp-Datei löschen.
  Ergebnis: „Wiederherstellung zuletzt erfolgreich getestet: <Datum>“ – das stärkste Vertrauenssignal für Nutzer.

### 7.7 Health-Bewertung

Pro Plan eine Ampel mit Begründung (in Übersicht, Menüleiste, Mitteilungen):
- 🟢 OK: letzter erfolgreicher Lauf < `warnAfter`, letzte Prüfung ok.
- 🟡 Warnung: Lauf älter als `warnAfter`, Warnungen im letzten Lauf, Ziel > 90 % voll, Verify überfällig.
- 🔴 Kritisch: älter als `criticalAfter`, Passwort fehlt/falsch, Verify fehlgeschlagen, FDA fehlt, Agent nicht erlaubt.
Jede Meldung hat eine **konkrete Aktion** („Laufwerk anschließen“, „Passwort eingeben“, „Festplattenvollzugriff öffnen“).

---

## 8. Sicherheit

1. **Secrets** (Repo-Passwort, S3-Keys, SFTP-Passwort/Key-Passphrase) ausschließlich im **Data-Protection-Keychain**
   (`kSecUseDataProtectionKeychain = true`), `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, Access Group geteilt zwischen
   App und Agent (Entitlement `keychain-access-groups`). `kSecAttrSynchronizable = false` (Standard; Option „über iCloud-Schlüsselbund
   synchronisieren“ nur bewusst, Phase 2).
2. **Keine Secrets** in: UserDefaults, config.json, Logs, Crash-Reports, argv, Diagnose-Export, XPC-Events. Die UI sendet ein
   Secret genau einmal per XPC an den Agent (beim Setzen) und bekommt es nie zurück. Ausnahme: „Passwort anzeigen“ im
   Wiederherstellungs-Kit, nur nach lokaler Authentifizierung (`LAContext`, `.deviceOwnerAuthentication`).
   WebDAV-Laufzeit-JSON ausschließlich im Speicher über die anonyme Pipe aus §6.2 ist erlaubt; keine Persistenz.
3. **Passwort-UX**: Zwei Felder (Eingabe + Bestätigung) beim Anlegen, `.textContentType(.newPassword)` (macOS schlägt starke
   Passwörter vor), Einfügen aus Enpass per ⌘V, Stärkeanzeige (zxcvbn-ähnliche Heuristik, Minimum: 12 Zeichen oder Stärke ≥ 3),
   „Passwort generieren“ (Diceware/random, 24+ Zeichen). Beim Verbinden `.textContentType(.password)`.
   Deutlicher Hinweis: **„Ohne dieses Passwort sind deine Backups unwiederbringlich verloren.“**
4. **Wiederherstellungs-Kit**: PDF (via `ImageRenderer`/`NSPrintOperation`) mit Repository-Typ, Pfad/URL, Benutzer@Host-Identität,
   Kopia-Version, Datum, optional dem Passwort sowie einer Kurzanleitung, wie man **ohne MacKopia** mit der Kopia-CLI wiederherstellt.
   Angeboten nach dem Anlegen, jederzeit erneut abrufbar.
5. **XPC-Härtung**: Swift-XPC-API (`XPCListener`/`XPCSession`) mit Peer-Requirement „gleiche Team-ID + exakte Bundle-ID“
   (`XPCPeerRequirement`, macOS 26) bzw. `NSXPCConnection.setCodeSigningRequirement` als Fallback. Alle Requests validieren
   (Pfade existieren, IDs bekannt, Größen begrenzt). Protokoll versioniert (`protocolVersion` im Handshake; Mismatch → UI fordert Neustart des Agents).
6. **Lokale Kopia-API**: nur `127.0.0.1`, TLS mit Pinning, Zufallspasswörter pro Start, stirbt mit dem Agent.
7. **Hardened Runtime** ohne Ausnahmen (keine `disable-library-validation`, kein JIT). Entitlements minimal:
   App: `keychain-access-groups`; Agent: `keychain-access-groups`. Kein Sandbox-Entitlement.
8. **Festplattenvollzugriff**: Prüfung durch Leseversuch einer TCC-geschützten Datei (z. B. `~/Library/Safari/Bookmarks.plist`,
   Fallback `~/Library/Mail`) **aus dem Agent-Prozess**. Fehlt FDA, führt die UI zu
   `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` und zeigt eine Schritt-für-Schritt-Grafik.
   **Spike (Phase 0)**: verifizieren, welchem Prozess TCC den Zugriff des Kindprozesses `kopia` zuordnet (verantwortlicher Prozess =
   Agent bzw. dessen Container-App?), und den Onboarding-Text exakt darauf abstimmen.
9. **SFTP**: Host-Key beim ersten Verbinden anzeigen (Fingerprint), vom Nutzer bestätigen lassen, in einer eigenen `known_hosts`
   pro Repo speichern (`--known-hosts=<datei>`). Keine stillschweigende Akzeptanz.
10. **S3**: Optional Object Lock/Retention-Mode beim Anlegen (Schutz gegen Ransomware). Credentials mit minimalen Rechten empfehlen (Hilfetext).
11. **Updates**: Sparkle 2 mit EdDSA-Signatur, Appcast nur über HTTPS, `SUVerifyUpdateBeforeExtraction`.
    Updates werden nicht installiert, solange ein Backup läuft.
12. **Diagnose-Export**: ZIP mit Logs (redigiert: Passwörter, Tokens, Keys, `SERVER PASSWORD`-Zeilen; Pfade optional anonymisierbar),
    Konfiguration ohne Secrets, Systeminfo. Vor dem Speichern Vorschau der enthaltenen Dateien.

---

## 9. Vorabprüfungen (Preflight) & bekannte Fallen

Vor **jedem** Lauf, in dieser Reihenfolge. Jede Prüfung liefert `ok | warning | blocking` und eine Aktion:

1. Kopia-Binary vorhanden, ausführbar, erwartete Version.
2. Secret im Schlüsselbund vorhanden (sonst `blocking`, Mitteilung „Passwort erforderlich“).
3. **Ziel-Identität**: Bei Dateisystem-Repos muss der Pfad auf dem Volume mit der erwarteten **UUID** liegen.
   ⚠️ Falle: `/Volumes/Backup` existiert als leerer Ordner, wenn das Laufwerk fehlt bzw. ein gleichnamiges anderes Laufwerk steckt
   (`Backup 1`). Niemals ein Repo auf dem falschen Volume anlegen oder öffnen.
4. Ziel erreichbar und beschreibbar (Testdatei im Repo-Root schreiben/löschen ist bei Kopia unnötig → stattdessen
   `repo/status` über den Server; für Dateisystem: Schreibrecht des Verzeichnisses).
5. Freier Speicher am Ziel (Dateisystem: `volumeAvailableCapacityForImportantUsageKey`; < 5 % oder < 5 GB → Warnung, < 1 GB → blocking).
6. **Quellen-Identität**: Quelle existiert **und** liegt auf dem erwarteten Volume (UUID). ⚠️ Falle: Externe Quelle nicht
   gemountet → leeres Verzeichnis → „leerer“ Snapshot. Fehlt die Quelle → diese Quelle `skipped`, kein leerer Snapshot.
7. Festplattenvollzugriff vorhanden, wenn Quellen TCC-geschützte Bereiche enthalten (Home, Desktop, Dokumente, Mail …).
8. Ausführungsbedingungen (Netzteil, Netzwerk, Stromsparmodus).
9. Kein anderer Lauf/Wartung auf demselben Repo aktiv.

`BackupPrerequisitePreflight` verbindet zunächst die ersten beiden Prüfschritte: frische Binary-Prüfung,
danach ausschließlich lesender Zugriff auf `Repository.secretRef` für das Backup-Passwort. Fehlendes Passwort
blockiert mit einer Eingabeaufforderung; Schlüsselbundfehler bleiben von „nicht vorhanden“ unterscheidbar.
Der Secret-Wert wird weder zurückgegeben noch in einem Preflight-Bericht gespeichert. Eine spätere Operation
muss ihn erneut lesen; Backend-Zugangsdaten für SFTP/S3/WebDAV sind damit noch nicht geprüft.

`KopiaBinaryVerifier` verlangt eine vorhandene reguläre ausführbare Datei ohne finalen Symlink und vergleicht
eine frische `--version`-Antwort mit der explizit aus `Config/kopia-version.json` zu liefernden Version.
Die Abfrage verwendet den nativen Runner ohne Secrets, mit isolierten Config-/Log-/Cachepfaden, Whitelist-Environment,
10 Sekunden Timeout, Abbrucheskalation/Reaping und höchstens 4 KiB pro Ausgabekanal. Nicht-Null-Exit,
fehlende/ungültige Antwort oder Versionsabweichung blockieren; rohe Prozessausgaben werden nicht weitergereicht.
Der selbst gemeldete Versionsstring ersetzt keine Download-Hash-/Signaturprüfung. Eine Dateiprüfung vor Spawn
verhindert keinen Austausch zwischen Prüfung und Ausführung; Bundle-Vertrauen/Release-Signierung und erneute
Prüfung vor produktiven Starts bleiben erforderlich. Die Verknüpfung mit Agent/Bundle-Pin und Live-Adaptern für alle Prüfschritte ist noch nicht implementiert.

Die erste Engine-Teilprüfung `BackupPathPreflight` prüft Plan-/Speicherziel-Zuordnung sowie Pfade und
Volume-Identitäten. Überlappende Quellen innerhalb eines Plans werden blockiert; Quelle und Dateisystem-Ziel
dürfen weder identisch noch ineinander enthalten sein. Verglichen werden Pfadkomponenten (kein bloßer
String-Präfix) sowie frisch ermittelte kanonische Pfade nach Symlink-Auflösung; auf Volumes ohne
Groß-/Kleinschreibung wird konservativ ohne diese Unterscheidung verglichen. Fehlende kanonische Pfad-,
Volume- oder Case-Sensitivity-Metadaten gelten als nicht verfügbare Beobachtung. Es werden ausschließlich
bestehende Verzeichnisse betrachtet, keine Eltern-Fallbacks, Verzeichniserstellung oder Mounts.

Ein Dateisystem-Ziel ohne gebundene UUID, auf falschem Volume oder mit fehlenden Metadaten blockiert die
Teilprüfung. Quellen mit fehlendem Verzeichnis, falscher Volume-UUID oder verweigertem Metadatenzugriff
werden einzeln als `skipped` ausgewiesen; ein späterer Lauf darf nur explizit geprüfte Quellen verwenden.
Sind alle übersprungen, darf kein Snapshot gestartet werden. Die Prüfung ist ein Zeitpunktbefund,
keine Startfreigabe: Reihenfolge aller neun Prüfungen oben, unmittelbare Wiederprüfung vor Operationen
und Live-Unmount-Überwachung müssen bei der Orchestrierung erhalten bleiben. Diese Teilprüfung implementiert
selbst noch keine Remote-Erreichbarkeit, Rechte-/Kapazitätsprüfung, FDA-Prüfung oder Keychain-/Binary-Prüfung. Alias-Konflikte zwischen verschiedenen Plänen, mehrfach registrierte physische Ziele sowie
Symlinks innerhalb des gesamten Quellbaums bleiben zusätzliche Prüfaufgaben.

`RunConditionEvaluator` wertet injizierte, kurzlebige Beobachtungen aus. Eingeschaltete Bedingungen benötigen
bekannte Werte; unbekannt bedeutet überspringen. Netzteilpflicht verlangt Netzstrom und ausgeschalteten
Stromsparmodus. Mindestladung wird bei vorhandener Batterie inklusive Grenzwert geprüft, bei sicher
bekanntem Desktop ohne Batterie nicht benötigt. Teure/eingeschränkte Netze werden unabhängig ausgewertet;
die konfigurierten Bedingungen gelten auch für lokale Ziele. Gespeicherte WLAN-Beschränkungen ohne den noch
fehlenden SSID-Monitor führen zu `wifiConditionUnavailable`, statt stillschweigend ignoriert zu werden.
Catch-up bleibt eine Scheduler-Regel. Kontinuierliche Power-/Netzwerk-Monitore und UI-Anzeigen dieser Gründe folgen separat.

`LocalRunEnvironmentSampler` ist der Standardadapter für Schritt 8 und verbindet zwei frische, parallele
SystemIntegration-Abfragen ohne Zustandscache: `LocalPowerStateSampler` liest IOKit-Power-Sources sowie
`ProcessInfo.isLowPowerModeEnabled`; `LocalNetworkPathSampler` nimmt das erste Update eines neuen
`NWPathMonitor` über dessen AsyncSequence entgegen. Das Netzwerkfenster beträgt fünf Sekunden mit
injizierbarer Clock; bei Timeout oder nicht erfülltem Netzwerkpfad bleiben beide Netzwerkwerte unbekannt.
Abbruch beendet den Monitor, der strukturierte Aufruf wartet auf die Bereinigung beider Kindaufgaben.
Es werden keine Verbindungen zu Speicherzielen und keine SSID-Abfragen ausgelöst. Dies bestätigt weder
Internet-/Ziel-Erreichbarkeit noch Backend-Zugangsdaten.

Die Energieabfrage unterscheidet interne Batterien von USV-Quellen. Nur eine vollständig bekannte Liste ohne
interne Batterie bestätigt einen Desktop ohne Batterie; fehlende Beschreibungen/Typen bleiben unbekannt.
Bei mehreren internen Batterien gilt der niedrigste ganzzahlig abgerundete Kapazitätsanteil; alle Werte müssen
gültig und die Batterien als vorhanden gemeldet sein. Fehlende, widersprüchliche oder überlaufende Werte
erfüllen keine Mindestladung. Netzstrom und Stromsparmodus bleiben unabhängig; USV-Betrieb erfüllt keine
Netzteilpflicht. Abfragen sind Zeitpunktbefunde, keine laufende Überwachung und kein atomarer gemeinsamer
Systemzustand. Vor produktiven Operationen müssen Bedingungen erneut geprüft werden; Trigger- und
Unmount-Monitore sowie Agent-Verdrahtung bleiben separat offen.

`FilesystemDestinationPreflight` ergänzt für bestehende lokale Ziele eine frische gemeinsame Beobachtung
von Volume-UUID, Verzeichnis-Schreibrecht und `volumeAvailableCapacityForImportantUsageKey` sowie
Gesamtkapazität. Falsche UUID, fehlende Metadaten oder fehlendes Schreibrecht blockieren; keine Testdatei
wird angelegt. Kapazitätsgrenzen sind dezimale GB: unter 1 GB blockierend, sonst unter 5 GB oder unter
5 % Warnung, bei exakter Grenze keine zusätzliche Warnung. Die Prozentprüfung bleibt auch bei Int64-Maximalwerten
überlauffrei. Dies ersetzt weder den Server-Status noch die unmittelbare Wiederprüfung vor Schreiboperationen;
Berechtigungen und Kapazität können sich jederzeit ändern.

`RepositoryOperationGate` ist eine gemeinsam zu verwendende Engine-Instanz für Backup und Wartung.
Sie lässt je Speicherziel-UUID höchstens eine Operation und global standardmäßig eine Operation zu;
ein positives höheres Limit erlaubt unterschiedliche Ziele parallel. Belegte Ziele bzw. ausgeschöpfte
Parallelität werden typisiert abgewiesen, noch nicht eingereiht. Die Sperre wird nach Rückkehr der Operation
auch bei Fehlern freigegeben; Cancellation allein gibt sie nicht vorzeitig frei. Die Operation muss deshalb
bis zum vollständigen Kindprozess-Cleanup/Reaping laufen. Auch verschachtelte Zugriffe werden abgewiesen.
Die Sperre gilt nur innerhalb dieser Instanz/des Prozesses; Agent-Verdrahtung, Queue/Fairness, Abgleich
mehrfach registrierter physischer Ziele und prozessübergreifende Sperren bleiben offen.

`BackupPreflight.evaluate` verbindet die Bausteine zu einem geordneten **Diagnoseablauf**. Sein Bericht enthält
nur typisierte Prüfschritte, Status/Grund, vorgeschlagene Aktion und Quellen-IDs mit ihren Statuswerten;
keine Pfade, Zugangsdaten oder rohen Adapterfehler. Bei einem blockierenden Fehler endet die Prüfung sofort,
bei niedriger Kapazität läuft sie mit Warnung weiter. Verfügbare Quellen bleiben in Planreihenfolge, fehlende
Quellen werden nicht an die Zugriffsprüfung übergeben. Sind alle Quellen übersprungen, lautet das Ergebnis
`skipped`. Nicht erfüllte Laufbedingungen führen ebenfalls zu `skipped`; erfolgreiche Einzelprüfungen ergeben
`checksPassed`, ausdrücklich keine wiederverwendbare Startfreigabe. Cancellation bleibt ein geworfener Abbruch
und wird nicht als Diagnosefehler gespeichert.

Die gemeinsame Operationssperre wird **vor jedem Adapterzugriff** reserviert, damit schon die Vorprüfung keine
konkurrierenden Zielzugriffe auslöst. Eine belegte Sperre beendet die Prüfung sofort mit Schritt 9 und Warteaktion;
bei erfolgreicher Reservierung werden die fachlichen Schritte 1–8 in Reihenfolge und Schritt 9 zuletzt berichtet.
Für Dateisystem-Ziele werden Identität vor Rechten/Kapazität und Quellen erst danach geprüft. Bei Remote-Zielen
sind lokale Volume-Identität/Kapazität als nicht anwendbar markiert; der injizierte Remote-Adapter muss Backend-
Zugangsdaten und authentifizierten Lese-/Schreibzugriff tatsächlich bestätigen. Der Quellzugriffsadapter muss
für sämtliche verfügbaren Quellen auch eventuell nötigen FDA-/TCC-Zugriff bestätigen. Fehlende Live-Adapter
melden `unknown` und blockieren; sie erteilen niemals pauschal Zugriff. Die Energie-/Netzwerkbeobachtung ist
in gleicher Weise injizierbar, unbekannte Werte erfüllen weiterhin keine eingeschaltete Bedingung.

Der Diagnoseaufruf gibt seine Sperre bei Rückkehr/Fehler frei. Ein späterer Backup-Start muss den gesamten
Prüf-/Sicherungs-/Cleanup-Lebenszyklus gemeinsam reservieren, die Prüfungen frisch ausführen und die Ziel-/
Quellenidentität unmittelbar vor Zugriff erneut prüfen sowie Unmounts überwachen. Weder Berichte aufbewahren
und später als Freigabe nutzen noch nach `evaluate` ungeschützt starten. Live-Adapter für FDA-/Quellzugriff und authentifizierten Remote-Zugriff, dieser
zusammenhängende Ausführungspfad, Queue und Agent-Verdrahtung sind noch offen.

`BackupOperationCoordinator.perform` ergänzt eine interne, noch nicht an Agent/Kopia angeschlossene
Operationsgrenze. Dieselbe Reservierung umfasst erste Vorprüfung, Aktivierung des injizierten
Laufwerksschutzes, vollständige frische Vorprüfung nach dieser möglichen Suspension, unmittelbare erneute
Ziel-/Quellenidentitätsprüfung, Operation und sämtliche Bereinigung. Ein abweichender Quellenstatus bei der
letzten Prüfung bricht ab; die Operation erhält ausschließlich die zuletzt verfügbaren Quellen in Planreihenfolge.
Blockierende/übersprungene Vorprüfungen starten keine Operation. Auch ein Abbruch während der asynchronen
Monitor-Bereinigung bleibt ein Abbruch und wird erst nach dieser Bereinigung weitergegeben.

Der Schutzadapter muss alle relevanten Volumes vor dem Callback überwachen, bei Verschwinden abbrechen,
das Prozess-Cleanup/Reaping abwarten und die Überwachung anschließend auf jedem Ausgang abbauen. Der
Standardadapter `UnavailableBackupOperationProtection` verweigert die Operation ausdrücklich. Der neue
`LocalBackupOperationProtection` kann explizit injiziert werden; produktive Agent-/Kopia-Operationen sind
weiterhin nicht angeschlossen. Die vertrauenswürdige Operationsimplementierung muss ausschließlich die
übergebenen Quellen verwenden, Secrets frisch auflösen und alle Kindprozesse selbst vollständig bereinigen.
Ein zurückgegebener Callback-Wert bestätigt keinen erfolgreichen Snapshot; spätere Kopia-Anbindung muss
dessen Ergebnis prüfen. Beliebige Adapter-/Prozessfehler werden an dieser Grenze statisch klassifiziert,
Cancellation und bekannte statische Fehler bleiben unterscheidbar. Diagnoseberichte bleiben Zeitpunktbefunde;
Queue, FDA-/Remote-Live-Adapter, Schutz für Netzwerk-Volumes und Agent-Anbindung sind weiterhin offen.

`LocalBackupOperationProtection` verbindet den reservierten Ablauf mit einer nativen
`LocalVolumeProtectionMonitor`-Sitzung für die zunächst verfügbaren Quellen und ein Dateisystem-Ziel.
Wird nach Aktivierung des Schutzes eine weitere Quelle verfügbar, wird dieser Versuch abgebrochen:
Eine Quelle ohne Schutzabdeckung darf nicht nachträglich in die Operation aufgenommen werden. Die Sitzung
bleibt bis zum Abschluss der strukturierten Operation einschließlich deren Abbruch-/Prozess-Cleanup aktiv.
Ein verschwundenes Volume ergibt `volumeDisappeared`; auch ein unerwartet beendeter Ereignisstrom beendet
die Operation. Ein abschließender aktiver Zustandscheck verhindert Erfolg bei bereits beobachtetem Verlust.

Die native Auflösung liest vorhandene lokale Verzeichnisse außerhalb des Main Actors und bestätigt die
gespeicherte UUID. **APFS-Firmlinks:** Foundation kann für einen Pfad auf dem Data-Volume `/` als Volume-URL
liefern; daraus darf nicht das Gerät abgeleitet werden. `statfs` liefert stattdessen das tatsächliche BSD-Gerät
und den Mountpunkt; anschließend müssen DiskArbitration-UUID und Mountpunkt unabhängig übereinstimmen.
Netzwerk-Volumes oder nicht eindeutig auflösbare Geräte werden derzeit abgewiesen, nicht ungeschützt zugelassen.
Gleiche Geräte werden dedupliziert; widersprüchliche UUID-/Mountbeobachtungen blockieren. Synchrone einzelne
OS-Metadatenaufrufe sind nicht mitten im Aufruf abbrechbar; Cancellation wird vor/nach der Auflösung geprüft.

DiskArbitration-Sitzung und Callbacks laufen serialisiert auf dem Main Actor mit dessen DispatchQueue als
nativer API-Grenze. Unmount-Anfragen für überwachte Volumes werden mit `kDAReturnBusy` und einer lokalisierten
Begründung abgelehnt. Verschwinden sowie Änderung/Verlust von Mountpunkt oder UUID erzeugen ein terminales
Ereignis. Die C-Callbacks tragen nur eine nicht wiederverwendete Kennung; eine schwache Main-Actor-Registry
löst die Sitzung auf. Abmelden invalidiert die Kennung zuerst, damit verspätete Callbacks keinen freigegebenen
Sitzungszeiger erreichen können. Callback-Abmeldung, Unscheduling und Stream-Ende sind idempotent; isolierter
Deinit dient als Rückfall. Keine `@unchecked Sendable`-/unsicheren Isolation-Ausnahmen.

Native Registrierung und C-Callback-Einstiege sind an einem temporären Verzeichnis geprüft; dabei werden
Unmount/Disappearance nur als Callback-Eingaben simuliert. Echte Eject-/Kabelzieh-/SMB-Tests, Mitteilung mit
„Backup stoppen & auswerfen“, manuelle Geräteabnahme und produktive Agent-Anbindung bleiben offen. Der
Standard des Coordinators bleibt bis zu dieser Anbindung ausdrücklich gesperrt. Es wird keine vollständige
Unmount-/Auswerfen-UX allein durch den nativen Adapter zugesagt.

**Weitere macOS-Fallen, die explizit behandelt werden müssen:**
- **iCloud Drive / File-Provider-Platzhalter** (Option „Speicher optimieren“, Dropbox, OneDrive): Das Lesen eines
  ausgelagerten Platzhalters löst einen **Download** aus. Standard: `~/Library/Mobile Documents` und `~/Library/CloudStorage`
  **ausschließen**, im Editor mit Erklärung. Experten-Option zum Einschließen mit Warnung.
- **Fotos-/Musik-Mediatheken** (`.photoslibrary`) sind Pakete: als Ganzes sichern, Hinweis „Fotos-App möglichst geschlossen halten“
  (Phase 2: APFS-Snapshot für Konsistenz).
- **Geöffnete Datenbanken** (Mail, Messages, Datenbanken von Entwicklertools) können inkonsistent sein → APFS-Snapshots Phase 2;
  in 1.0 dokumentieren.
- **Dateinamen mit Unicode-Normalisierung (NFD/NFC)** und sehr lange Pfade: Restore-Tests mit solchen Fixtures.
- **Erweiterte Attribute, Ressourcen-Forks, ACLs, Finder-Tags**: Der erste Spike mit Kopia 0.23.1 stellt diese Metadaten
  im CLI-Standardworkflow nicht wieder her (siehe §17 und `metadata-report.json`). In der Hilfe und im Restore-UI als bekannte
  Einschränkung nennen; keine vollständige macOS-Metadatenwiederherstellung zusagen.
- **Mehrere Benutzer auf demselben Mac / dasselbe Repo von zwei Macs**: durch die Identität `user@host` getrennt. Snapshots
  anderer Rechner im Restore-Browser anzeigen (Filter), aber standardmäßig nicht anfassen.
- **Uhrzeit-Sprünge / Zeitzonen**: Zeitpläne in lokaler Zeit über `Calendar`, gespeicherte Zeitpunkte immer als UTC-`Date`.

---

## 10. Ausschlüsse – macOS-Standardvorgaben

Aktiv bei `useMacOSDefaults` (als Kopia-Ignore-Regeln relativ zur Quelle bzw. global, Liste versioniert im Code):

```
.Trash/                          .DS_Store                     .Spotlight-V100/     .fseventsd/
Library/Caches/                  Library/Logs/                 Library/Containers/*/Data/Library/Caches/
Library/Application Support/MobileSync/Backup/   # optional, groß (iPhone-Backups) – im Editor als Schalter
Library/Developer/Xcode/DerivedData/             Library/Developer/CoreSimulator/Caches/
Library/Mobile Documents/        Library/CloudStorage/         # siehe iCloud-Falle
.cache/                          node_modules/  (Schalter „Entwickler-Ordner ausschließen“: node_modules, .build, DerivedData, target, .venv)
*.tmp                            *.swp
```
- `ignoreCacheDirs` → Kopia-Policy „Cache-Verzeichnisse ignorieren“ (`CACHEDIR.TAG`).
- `honorTimeMachineExclusions` → beim Policy-Abgleich die Quelle flach bis Tiefe 3 nach `URLResourceKey.isExcludedFromBackupKey`
  scannen (plus `tmutil`-Sticky-Exclusions via `com_apple_backup_excludeItem`-xattr) und als Ignore-Regeln übernehmen.
  Scan im Hintergrund mit Limit (max. 10 s), Ergebnis cachen.
- `oneFileSystem` (Standard an) → keine anderen Volumes unter der Quelle mitsichern.
- Der Editor zeigt die **effektiven** Regeln (`policy/resolve`) und eine Vorschau „X Dateien / Y GB werden gesichert“ (`/api/v1/estimate`).

**Aufbewahrungs-Presets:**
| Preset | latest | hourly | daily | weekly | monthly | annual |
|---|---|---|---|---|---|---|
| Ausgewogen (Standard, entspricht in etwa Kopia-Default) | 10 | 48 | 14 | 8 | 24 | 3 |
| Platzsparend | 5 | 24 | 7 | 4 | 6 | 1 |
| Maximal | 20 | 72 | 60 | 26 | 60 | 10 |
| Eigene | frei | | | | | |

---

## 11. UI/UX-Spezifikation

### 11.1 Prinzipien
- Nur Standardkomponenten: `NavigationSplitView`, `List` mit `Section`, `Table`, `Form` (`.formStyle(.grouped)`), `Inspector`,
  `ControlGroup`, `Toolbar`, `.searchable`, `ContentUnavailableView`, `ProgressView`, `Gauge`, `LabeledContent`, `Settings`-Scene,
  `MenuBarExtra`. Liquid Glass ergibt sich automatisch. Keine eigenen Hintergründe hinter Toolbars/Sidebars, `.glassEffect` höchstens punktuell.
- SF Symbols mit Zustandsvarianten (`.symbolEffect` für laufende Backups, z. B. `arrow.triangle.2.circlepath` mit `.rotate`).
- **Progressive Offenlegung**: Standardnutzer sehen Ziel, Quellen, Zeitplan. „Erweitert“ (DisclosureGroup) enthält Kompression,
  Parallelität, Checkpoints, Bandbreite.
- Jede Fehlermeldung = **Was ist passiert + Warum + Was tun (Button)**. Keine rohen Kopia-Meldungen in der Hauptansicht
  (in „Details“ ausklappbar).
- Volle Tastaturbedienung, VoiceOver-Labels für alle Icons/Status, Dynamic Type, ausreichender Kontrast, `accessibilityValue`
  für Fortschritt. Menübefehle mit Shortcuts (⌘N neuer Plan, ⌘B jetzt sichern, ⌘R wiederherstellen).
- Bestätigungsdialoge (`.confirmationDialog`) nur für destruktive Aktionen (Snapshot löschen, Repo entfernen, Überschreiben beim Restore).

### 11.2 Hauptfenster

```
┌ Sidebar ───────────────┬ Inhalt ─────────────────────────────────────────────┬ Inspector (optional) ┐
│ Übersicht              │  Übersicht: Kacheln pro Plan (Ampel, letzter/       │ Details zum           │
│ ── Backup-Pläne ──     │  nächster Lauf, Größe, Ziel), globaler Status,       │ ausgewählten Element  │
│   ● Dokumente → NAS    │  laufender Fortschritt (ProgressPanel), Hinweise     │                       │
│   ● Alles → USB        │                                                      │                       │
│   + Neuer Plan         │  Plan-Detail: Kopfzeile mit Status + ControlGroup    │                       │
│ ── Speicherziele ──    │  [Jetzt sichern | Pausieren ▾ | Stoppen],            │                       │
│   NAS (SMB)            │  Tabs/Sections: Quellen · Zeitplan · Aufbewahrung ·  │                       │
│   USB „Tresor“         │  Ausschlüsse · Verlauf                               │                       │
│ Wiederherstellen       │                                                      │                       │
│ Aktivität              │                                                      │                       │
└────────────────────────┴──────────────────────────────────────────────────────┴───────────────────────┘
```

- **Quellen-Liste**: Pfad + Volume-Badge + geschätzte Größe, Hinzufügen per `NSOpenPanel` (`canChooseDirectories`,
  `canChooseFiles`, `allowsMultipleSelection`), Drag & Drop (`.dropDestination(for: URL.self)`), Entfernen per Entf/Kontextmenü.
  Warnung, wenn sich Quellen überlappen (Unterordner einer anderen Quelle) oder eine Quelle im Repo-Ziel liegt (Rekursion!).
- **ProgressPanel**: Phase („Dateien werden verglichen“, „Wird hochgeladen“, „Wird abgeschlossen“), lineare `ProgressView`
  (bestimmt/unbestimmt), Zeilen: „3,2 GB von 41 GB · 12.345 Dateien · 24 MB/s · noch ca. 18 Min.“, aktuelle Datei (gekürzt
  in der Mitte, `.truncationMode(.middle)`), Buttons Pausieren/Stoppen.
- **Wiederherstellen**: Links Filter (Plan/Quelle/Rechner), Mitte `Table` der Snapshots (Datum, Größe, Dateien, Grund der
  Aufbewahrung, Pin, Beschreibung), darunter/rechts Browser als `List` mit `DisclosureGroup`/Spaltenansicht.
  Leertaste = Quick Look (Datei über `/api/v1/objects/{oid}` in `~/Library/Caches/MacKopia/QuickLook/` laden, beim Schließen löschen).
  „Wiederherstellen…“ → Sheet: Ziel (Standard: `~/Downloads/MacKopia-Wiederherstellung <Datum>/`), Optionen
  [ ] Vorhandene Dateien überschreiben (Standard aus), [x] Berechtigungen/Zeitstempel übernehmen, Zusammenfassung, Start.
  „An ursprünglichem Ort wiederherstellen“ nur mit expliziter Bestätigung und Standard „vorhandene überspringen“.
  Suche über Dateinamen im ausgewählten Snapshot (lazy, mit Abbruch).
- **Aktivität**: `Table` aller `JobRun`s (Plan, Trigger, Start, Dauer, Ergebnis, Datenmenge), Detail mit Fehlerliste
  (Datei + Grund) und „Kopia-Log anzeigen“.

### 11.3 Menüleiste (Agent)
Icon-Zustände: idle (Häkchen), läuft (animiert), pausiert, Warnung, Fehler. Inhalt (`.menuBarExtraStyle(.window)`):
Status je Plan (Ampel, „vor 12 Min.“), laufender Fortschritt, Buttons „Jetzt sichern“ (alle/Plan), „Pausieren ▸ 1 Std. /
bis morgen / unbegrenzt“, „MacKopia öffnen“, „Wiederherstellen…“. Es gibt bewusst **kein** einfaches „Beenden“:
„Hintergrunddienst beenden“ steht unter „Erweitert“, deaktiviert alle automatischen Backups und verlangt eine Bestätigung.

### 11.4 Mitteilungen (`UserNotifications`, aus dem Agent)
- Nur relevante: Fehler, Warnungen, „Laufwerk erkannt – Backup gestartet“ (abschaltbar), erstes erfolgreiches Backup,
  Health kritisch (max. 1×/Tag), Plausibilitätswarnung. Erfolgsmeldungen bei jedem Lauf standardmäßig **aus**.
- Aktionen in Mitteilungen: „Erneut versuchen“, „Details“, „Backup stoppen & auswerfen“.

### 11.5 Lokalisierung
`Localizable.xcstrings` (Deutsch = Entwicklungssprache, Englisch vollständig), Pluralregeln über den Katalog,
Byte-/Datumsformatierung ausschließlich mit `ByteCountFormatStyle`, `Date.FormatStyle`, `Duration.UnitsFormatStyle`,
`.relative(presentation:)`. Keine zusammengesetzten Strings, keine hartcodierten Formate.

---

## 12. App ↔ Agent-Protokoll

- Transport: Swift-XPC (`XPCSession`), Nachrichten als `Codable` (gemeinsames Modul `AgentProtocol`).
- **Requests** (async, mit Ergebnis): `getState`, `listPlans`, `upsertPlan`, `deletePlan`, `listRepositories`, `createRepository`,
  `connectRepository`, `testRepository`, `setSecret`, `runNow(planID)`, `pause(scope, until)`, `resume(scope)`, `stop(planID)`,
  `listSnapshots(repoID, filter)`, `browse(repoID, objectID)`, `fetchFileForPreview`, `startRestore(request)`, `cancelTask`,
  `history(query)`, `exportDiagnostics`, `checkPermissions`.
- **Events** (Stream vom Agent an verbundene UIs): `stateChanged`, `progress(planID, BackupProgress)`, `runFinished(JobRun)`,
  `healthChanged`, `taskProgress`. Die UI hält ein `AppState`-Snapshot + wendet Events an. Beim Reconnect lädt sie `getState` neu.
- UI-Stores (`@Observable @MainActor`): `AgentConnection`, `OverviewStore`, `PlansStore`, `RepositoriesStore`, `RestoreStore`,
  `ActivityStore`. Views bekommen Stores über `@Environment`. Keine Geschäftslogik in Views.
- Phase-0-Ping: `AgentPingRequest` mit fester Protokollversion (aktuell 1) und UUID zur Antwortzuordnung;
  unpassende Version/UUID wird abgewiesen. `AgentPingClient` hat eine 5-s-Antwortfrist und Task-Cancellation,
  `AgentPingServer` akzeptiert nur die exakte App-Signaturidentität desselben Teams. Beide prüfen zusätzlich
  die eigene gültige Team-Signatur; ad-hoc/unsignierte Builds erhalten keinen ungesicherten Ersatztransport.
  `AgentServiceRegistration` kapselt explizite Registrierung, Status und den Sprung zu Anmeldeobjekt-Einstellungen.
  Der Agent startet den Listener beim App-Start. UI-Anbindung sowie echter signierter Ende-zu-Ende-Ping sind noch offen.
- Ist der Agent nicht erreichbar: UI zeigt Banner „Hintergrunddienst nicht aktiv“ + Button (Registrierung/Neustart über `SMAppService`).

---

## 13. Qualitätssicherung

### 13.1 Teststrategie
| Ebene | Inhalt | Werkzeug |
|---|---|---|
| Unit | Domain-Validierung, Scheduler (mit injizierter `Clock`), Retry, Health, PolicyTranslator, Fehler-Mapping, DTO-Decoding (Fixtures), Config-Migration, Redaktion | Swift Testing |
| Contract | Echte JSON-Antworten von Kopia 0.23.1 (CLI + REST) als Fixtures; Test schlägt fehl, wenn eine Kopia-Version sie anders liefert | Swift Testing + Skript zum Neuaufzeichnen |
| Integration | Echtes mitgeliefertes Kopia gegen Dateisystem-Repo in Temp-Verzeichnis: create → snapshot → cancel → resume → list → browse → restore → verify → maintenance; falsches Passwort; Ziel verschwindet während des Laufs | Swift Testing (Tag `.integration`) |
| Fehlerinjektion | `FakeKopia`: kleines Executable, das Exit-Codes, Hänger, riesige stderr-Ausgaben, kaputtes JSON simuliert | TestSupport |
| UI | Smoke: Onboarding, Plan anlegen, manuelles Backup, Restore einer Datei | XCUITest |
| Manuell (Release-Checkliste) | USB anstecken/abziehen während Backup, SMB-Server weg, Sleep während Backup, Neustart während Backup, FDA entziehen, Agent killen (KeepAlive), Update während Backup | Checkliste in `docs/RELEASE-CHECKLIST.md` (in Phase 7 anlegen) |

Testdaten-Fixtures: Unicode (NFD/NFC), Leerzeichen/Emoji in Pfaden, 0-Byte-Dateien, Symlinks, sehr tiefe Pfade, große Datei (> 4 GB, sparse),
Pakete (`.app`, `.photoslibrary`-Dummy), Dateien ohne Leserecht.

### 13.2 CI (GitHub Actions, macOS-Runner)
`fetch-kopia` (gecacht) → `swift test` (Package, Unit + Contract) → `xcodebuild test` (App, UI-Smoke) → Integrationstests →
bei Tag: Archive, Signieren, Notarisieren, DMG, Appcast. `swift format lint --strict` (Apples swift-format aus der Toolchain,
Konfiguration `.swift-format` im Repo) als Pflicht-Check.

### 13.3 Code-Regeln für Agents/Entwickler
- Swift 6 strict concurrency ohne `@unchecked Sendable` (Ausnahmen begründen + Kommentar). Kein `DispatchQueue` in neuem Code
  außer an AppKit/IOKit-Grenzen.
- Kein `try!`, kein `fatalError` außer bei Programmierfehlern in Debug. Kein Force-Unwrap außerhalb von Tests.
- Fehler sind typisiert (`enum … : Error, LocalizedError`) mit Nutzertext (lokalisiert) + technischem Detail.
- Jede öffentliche API in `MacKopiaKit` hat einen Test. Jede gefundene Kopia-Eigenheit bekommt einen Kommentar mit Kopia-Version.
- Logger-Interpolationen mit `privacy: .private` für Pfade und `.public` nur für nicht-sensible Werte.
- Views < 200 Zeilen, Unterviews extrahieren; Previews mit Mock-Stores für jeden Bildschirm.
- Keine neuen Abhängigkeiten ohne Eintrag im Entscheidungslog.

---

## 14. Umsetzungsplan (Phasen mit Abnahmekriterien)

> Jede Phase endet mit grünen Tests, lauffähigem Build und einem kurzen Eintrag im Entscheidungslog (Abschnitt 17).
> **Reihenfolge einhalten**: Die Engine wird vor der UI fertig und getestet (UI ist austauschbar, Datenverlust nicht).

### Phase 0 – Fundament & Spikes (Risiken zuerst)
1. Xcode-Projekt (App + Agent), lokales Package `MacKopiaKit` mit allen Modul-Targets (leer), xcconfigs, Bundle-IDs, Team,
   Hardened Runtime, Entitlements, String Catalog, swift-format (`.swift-format` liegt bereits im Repo), CI-Grundgerüst.
2. `Scripts/fetch-kopia.sh` + Build-Phase: Kopia 0.23.1 universal, signiert, unter `Contents/Helpers/kopia`.
3. **Spike A – Server-Handshake**: Server mit obigem Kommando starten, Handshake-Zeilen parsen, `GET /repo/status` mit
   Pinning + Basic-Auth. Echte Antworten von `sources`, `snapshots`, `objects`, `tasks`, `estimate`, `restore` als Fixtures speichern.
4. **Spike B – Abbruch-Semantik**: großen Snapshot starten, `sources/cancel`, prüfen: unvollständiger Snapshot/Checkpoint vorhanden?
   Zweiter Lauf schneller? Policy-Flag für Checkpoint-Intervall verifizieren.
5. **Spike C – TCC/FDA**: Agent via `SMAppService` registrieren, `kopia` als Kind starten, geschützten Ordner sichern.
   Ergebnis: Welcher Eintrag muss in „Festplattenvollzugriff“? Onboarding-Text festlegen.
6. **Spike D – Secrets via Umgebung**: Für jedes Backend (filesystem, sftp, webdav, s3) verifizieren, wie Secrets ohne argv übergeben werden.
   Ergebnis: [Spike-D-Bericht](SPIKE-D-SECRETS.md). S3/WebDAV persistieren Backend-Secrets trotz Environment-Übergabe; SFTP hat kein Passwort-Environment-Binding. Folge-Spike: S3 ohne Credential-Felder mit Environment, WebDAV via anonymer Config-Pipe (Backup/Restore + EOF-Shutdown) erfolgreich. WebDAV-`--create-only`, Aufbewahrung/Owner, schnelle Wartung und Wiederverbindung/Restore nach Prozessabsturz inzwischen geprüft; geschützter Symlink-/Lock-Pfad nötig. WebDAV-Pipe-Übergabe für Produktion freigegeben (§6.2/§8); Swift-Integration, S3-Bootstrap und SFTP bleiben offen.
7. **Spike E – Metadaten**: xattrs/Finder-Tags/ACLs/Ressourcen-Forks nach Restore prüfen.
**Abnahme:** Leere App + Agent starten, Agent erscheint in der Menüleiste, XPC-Ping UI→Agent funktioniert (Peer-Requirement aktiv),
Spike-Ergebnisse im Entscheidungslog dokumentiert, Fixtures eingecheckt.

### Phase 1 – KopiaCLI & KopiaServer (Package)
`KopiaProcess`, `KopiaBinaryLocator`, `KopiaCommand`s, Fehler-Mapping (Tabelle Abschnitt 15), `KopiaServerProcess`
(Start/Handshake/Idle-Stop/Orphan-Cleanup), `KopiaServerClient` (Pinning, DTOs, alle Endpunkte aus 6.4).
**Abnahme:** Integrationstest legt Dateisystem-Repo an, erstellt Snapshot über den Server, liest Fortschritt, bricht ab,
setzt fort, listet, browst, stellt eine Datei wieder her (Byte-identisch), führt Verify + Maintenance aus. Falsches Passwort → `.wrongPassword`.

### Phase 2 – Domain, Persistenz, Secrets
Modelle + Validierung, `ConfigStore` mit Migration v1, `HistoryStore` (GRDB, Schema v1), `KeychainStore`, `PolicyTranslator`.
**Abnahme:** Unit-Tests für alle Validierungsregeln (Überlappung, Quelle im Ziel, doppelte Quelle pro Repo), Roundtrip/Migration,
Keychain-Tests (eigene Test-Access-Group), Policy-Abgleich idempotent (zweiter Abgleich = keine Änderung).

### Phase 3 – Engine (Agent ohne UI)
Scheduler, TriggerMonitore, PowerMonitor, NetworkMonitor, SleepAssertion, Preflight, JobQueue mit Zustandsmaschine, Retry,
Pause/Resume/Stop, Plausibilitätswächter, Maintenance-/Verify-Coordinator, Test-Restore, Health, Notifications, XPC-Server mit vollem Protokoll.
**Abnahme:** Scheduler-Tests mit virtueller Uhr (inkl. Sleep-/Wake-Nachholen, Zeitzonenwechsel), Engine-Integrationstest:
Plan mit 2 Quellen → Lauf → Historie korrekt; USB-Simulation (Disk-Image per `hdiutil` erzeugen/mounten/aushängen) → Trigger feuert,
Unmount-Schutz greift; Fehlerinjektion → Retry-Verhalten korrekt.

### Phase 4 – App-Grundgerüst & Onboarding
`AgentConnection`, Stores, `NavigationSplitView`-Layout, Übersicht, Onboarding-Assistent komplett (inkl. FDA- und Login-Item-Status,
Recovery-Kit-PDF), Repository-Assistenten für alle 4 Typen (inkl. SFTP-Host-Key-Bestätigung, S3-Verbindungstest), Import bestehender Kopia-Config.
**Abnahme:** Frischer Mac-Benutzer gelangt in < 3 Minuten zum ersten laufenden Backup; alle Assistenten haben Fehlerpfade mit Aktionen.

### Phase 5 – Pläne, Steuerung, Fortschritt, Menüleiste
Plan-Editor (Quellen inkl. Drag & Drop, Zeitplan, Bedingungen, Aufbewahrung, Ausschlüsse mit Vorschau), ControlGroup,
ProgressPanel, Menüleisten-UI, Mitteilungsaktionen, Aktivitätsansicht.
**Abnahme:** Alle Aktionen funktionieren aus Hauptfenster **und** Menüleiste; UI bleibt bei 1 Mio. Dateien flüssig (Fortschritt gedrosselt).

### Phase 6 – Wiederherstellen
Snapshot-Tabelle mit Filtern, Browser, Suche, Quick Look, Restore-Sheet, Task-Fortschritt/Abbruch, Snapshot pinnen/beschreiben/löschen.
**Abnahme:** Wiederherstellung von Einzeldatei, Ordner, ganzem Snapshot. Byte-Vergleich in Tests; Überschreiben nur nach Bestätigung;
Restore aus Snapshots eines anderen Rechners möglich.

### Phase 7 – Härtung & Release
Einstellungen komplett, Sparkle, Diagnose-Export, Lokalisierung EN vollständig, Barrierefreiheits-Audit (Accessibility Inspector),
Performance (Instruments: Speicher < 150 MB Agent im Leerlauf, CPU ≈ 0 % im Leerlauf), `docs/RELEASE-CHECKLIST.md`,
Benutzerhilfe (`docs/HILFE.md`, inkl. „Wiederherstellen ohne MacKopia“), Signieren/Notarisieren/DMG in CI.
**Abnahme:** Release-Checkliste vollständig grün auf macOS 26 und 27, Intel + Apple Silicon.

---

## 15. Fehler-Mapping (Startpunkt, im Spike mit echten Meldungen ergänzen)

| Erkennung (stderr/HTTP, englisch) | `KopiaError.Kind` | Transient? | Nutzertext (DE) | Aktion |
|---|---|---|---|---|
| `invalid repository password` | `.wrongPassword` | nein | „Das Passwort für dieses Speicherziel ist falsch.“ | Passwort eingeben |
| `repository not initialized` / `not found` | `.repositoryNotFound` | nein | „Am Ziel wurde kein Backup-Speicher gefunden.“ | Ziel prüfen / neu anlegen |
| `no such file or directory` (Repo-Pfad) | `.targetUnavailable` | ja | „Das Ziel ist nicht verfügbar.“ | Laufwerk anschließen |
| `connection refused` / `timeout` / `no route` | `.network` | ja | „Keine Verbindung zum Ziel.“ | Erneut versuchen |
| `permission denied` (Quelle) | `.permissionDenied` | nein | „Kein Zugriff auf einige Dateien.“ | Festplattenvollzugriff |
| `no space left on device` | `.targetFull` | nein | „Das Ziel ist voll.“ | Aufbewahrung anpassen |
| HTTP 401 vom eigenen Server | `.serverAuth` | ja (Server neu starten) | intern | – |
| `unsupported repository format` / Version | `.formatIncompatible` | nein | „Dieses Backup wurde mit einer neueren Kopia-Version erstellt.“ | MacKopia aktualisieren |
| unbekannt | `.unknown` | einmal | „Unerwarteter Fehler.“ | Details/Diagnose |

Fehler-Mapping gehört in **eine** Datei mit Tests pro Zeile.

---

## 16. Offene Punkte (vor Phase 0 klären)

1. Endgültiger App-Name (Markenprüfung; „Kopia“ im Namen ggf. mit dem Kopia-Projekt abstimmen) und Bundle-ID-Präfix.
2. **Für spätere Releases zurückgestellt:** Apple Developer Team-ID, Developer-ID-Signierung und Notarisierung; der Nutzer hat derzeit keine Developer ID. Keine Voraussetzung für die laufende signierungsunabhängige Entwicklung. Hosting für Appcast/DMG (z. B. GitHub Releases) später festlegen.
3. Lizenzmodell der App (Open Source? Bezahl-App? Beeinflusst Sparkle-Feed und Website, nicht die Architektur).

---

## 17. Entscheidungslog

| Datum | Entscheidung | Grund |
|---|---|---|
| 2026-10-23 | Hybrid-Integration: `kopia server` (lokal, TLS-Pinning) + CLI `--json` | Strukturierter Fortschritt, Abbruch, Browsing |
| 2026-10-23 | Engine-Vorabprüfung trennt blockierende Zielprobleme von übersprungenen Quellen; fehlende Beobachtung erfüllt keine Bedingung | §9 präzisiert Pfad-/Volume-Teilprüfung, Überschneidungen, Fallunterscheidung und temporär nicht auswertbare WLAN-Bedingung; keine Job-Startfreigabe oder neue Systemrechte. |
| 2026-10-23 | ConfigStore verwendet schema-1-Hülle, begrenzte Dokumente und POSIX-atomaren Austausch statt Data.write(.atomic) | 0600 bereits vor dem ersten Byte, verzeichnisgebundener Austausch, Schreibsperre und validierte explizite Recovery; §7.2 präzisiert. Keine Kopia- oder Secret-Dateien. |
| 2026-10-23 | Plan-Modelle validieren Init/Decoding, Preset-Konsistenz und begrenzte Konfiguration; Quellenkonflikte gelten auch für deaktivierte Pläne | Verhindert ungültige Scheduler-/Policy-Eingaben und spätere stille Policy-Überschreibung; §7.1 präzisiert technische Grenzen. Keine Laufzeit-/Löschaktion. |
| 2026-10-23 | Mindest-OS macOS 26 Tahoe | Liquid Glass, aktuelle SwiftUI/XPC-APIs |
| 2026-10-23 | Kopia 0.23.1 im Bundle mitgeliefert, Version gepinnt | Reproduzierbarkeit, Unabhängigkeit von Homebrew |
| 2026-10-23 | Ziele v1: Dateisystem (lokal/USB/SMB), SFTP, WebDAV, S3-kompatibel | Nutzerwunsch |
| 2026-10-23 | Menüleiste + Agent (`SMAppService`), UI über XPC | Backups unabhängig vom Fenster, Neustart nach Absturz |
| 2026-10-23 | Developer ID + Sparkle 2 | Sandbox nicht möglich (FDA, CLI) |
| 2026-10-23 | Deutsch + Englisch via String Catalog | Nutzerwunsch |
| 2026-10-23 | v1 enthält: mehrere Pläne, Restore-Browser, Aufbewahrung/Ausschlüsse, Prüfung/Berichte | Nutzerwunsch |
| 2026-10-23 | Pause = Abbruch mit Checkpoint, Fortsetzen = neuer Lauf | Kopia kennt kein echtes Pausieren; Dedup macht Neustart billig |
| 2026-10-23 | Zeitpläne nur in MacKopia, keine Kopia-Scheduling-Policies | Eine einzige Wahrheit, Trigger mit Bedingungen |
| 2026-10-23 | APFS-Snapshots, Hooks, Finder-Mount → Phase 2 | Privilegierter Helper nötig bzw. nicht kritisch für 1.0 |
| 2026-10-23 | Phase-0-Gerüst vorerst mit `MacKopia`, `com.example.MacKopia` und leerer Team-ID; lokale Builds ad-hoc signiert | Vom Nutzer bestätigt; finale Identität und Developer-ID-Signierung bleiben offen |
| 2026-10-23 | Zunächst leere Package-Module, App und eingebetteter Agent ohne Registrierung, XPC oder Kopia; keine zusätzlichen Entitlements | Kleiner, separat prüfbarer erster Schritt von Phase 0; noch kein abgeschlossener Phasenstand |
| 2026-10-23 | Phase-0-Build prüft beide Architektur-Archive gegen festgeschriebene SHA256-Werte, erzeugt Universal-Kopia und signiert den eingebetteten Helper mit der App-Identität | Umsetzung von §6.1; Hashes mit offiziellen Release-Metadaten und `checksums.txt` abgeglichen; lokal ad-hoc, bei Developer-ID mit Timestamp |
| 2026-10-23 | Kopia-0.23.1-Lizenzbeilage: unveränderte `LICENSE` und `README.md` aus beiden verifizierten Archiven unter `Resources/Kopia` | Die offiziellen macOS-Archive enthalten keine `NOTICE`; keine erfundene Upstream-Datei beilegen. Darstellung im Über-Fenster folgt später |
| 2026-10-23 | Cache-Pfad bei `repository create/connect` und `server start` per `--cache-directory` setzen; weitere Aufrufe mit isolierter Config und `KOPIA_CACHE_DIRECTORY` | Kopia 0.23.1 lehnt das Flag global ab; `server start` verwendet denselben Connect-Flagblock. Präzisierung vom Nutzer bestätigt; Isolation bleibt unverändert |
| 2026-10-23 | Kopia 0.23.1 speichert den Cache-Pfad nach Möglichkeit relativ zur Config-Datei | Isolationsprüfung muss den gespeicherten Pfad gegen das Config-Verzeichnis auflösen; Probe auch mit abweichendem Arbeitsverzeichnis erfolgreich |
| 2026-10-23 | Spike E (CLI-Standardworkflow): Inhalte, Symlinks, POSIX-Modus und mtime erhalten; xattrs, Finder-Tags, ACLs und Ressourcen-Forks fehlen nach Restore | Reproduzierbar mit `Scripts/spike-kopia-cli.py`; Quellmetadaten vor Snapshot geprüft. Einschränkung in späterer Hilfe/Restore-UI offenlegen; noch keine vollständige macOS-Metadatenzusage |
| 2026-10-23 | Server mit `--ui`, `--tls-print-server-cert` und `--no-async-repo-connect` starten; CSRF-Sitzung nur flüchtig über `GET /` aufbauen | Spike A: `--no-ui` deaktiviert die REST-UI-API; Basic Auth allein liefert ohne CSRF auch bei GET 401. TLS 1.3, Leaf-Pinning, getrennte Control-Zugangsdaten und stdin-EOF-Shutdown gegen echtes Kopia geprüft |
| 2026-10-23 | Vollständiger REST-Restore mit `restoreDirEntryAtDepth = 2147483647`; neuesten Snapshot explizit nach Startzeit wählen | Spike A: REST-Tiefe 0 erzeugt Platzhalter; die Snapshot-API liefert nicht automatisch den neuesten Eintrag zuerst. Restore mit expliziten sicheren Optionen bytegleich geprüft |
| 2026-10-23 | REST-Methoden korrigiert: `POST /policy/resolve`, `PUT /repo/throttle` | Routen im Quellcode des Tags v0.23.1 geprüft; `PUT /repo/throttle` in Spike B geprüft; `POST /policy/resolve` noch nicht live geprüft |
| 2026-10-23 | Spike B: API-Abbruch erzeugt `incomplete: "canceled"`; Wiederverwendung nach Server-Neustart und vollständiger Restore von 128 Dateien / 256 MiB geprüft | Aktive Zähler können `uploadedBytes = 0` zeigen. Abbruch wartet auf Flush; Antwort ist nur Anforderungsbestätigung. Laufzeiten sind Beobachtungen, keine Garantien |
| 2026-10-23 | Checkpoint-Vorgabe 15 Min. im Serverbetrieb weiterhin offen; kein entsprechendes Policy-Feld/Server-Flag in Kopia 0.23.1 | Pinned Quellcode: CLI-only `--checkpoint-interval`, dort 15m akzeptiert, maximal 45m; Server nutzt unveränderten 45-Minuten-Standard. Kein Wechsel der Backup-Architektur ohne weitere Entscheidung |
| 2026-10-23 | Phase-0-XPC-Fundament mit Swift-XPC, gleicher Team-ID und exakter Signaturidentität in beiden Richtungen; kein Ad-hoc-Fallback | Eigene Signatur zusätzlich prüfen; versionierter Ping, UUID-Abgleich, Deadline/Cancellation. LaunchAgent aus Bundle-ID erzeugt, keine neuen Entitlements/Build-Phasen |
| 2026-10-23 | Echte Entwicklungssignierung und damit positiver XPC-/SMAppService-/TCC-Test werden vorerst verschoben | Nutzer bestätigt: Signierung später einrichten, unabhängig prüfbare Teile fortsetzen. Lokal keine gültige Codesigning-Identität; Tests verwenden nur Fakes bzw. absichtlich ungültige Identität |
| 2026-10-23 | Apple-Entwicklungssignierung, Developer-ID-Signierung und Notarisierung ausdrücklich erst für spätere Releases; keine Einrichtung während der laufenden Entwicklung | Nutzer hat keine Developer ID. Signaturabhängige Live-Tests zurückstellen, unabhängige Entwicklung fortsetzen; lokale technische Ad-hoc-Builds benötigen kein Apple-Konto und ersetzen keine Team-Signatur |
| 2026-10-23 | Spike D: Environment-Übergabe verhindert bei Kopia 0.23.1 nicht das Persistieren von S3-/WebDAV-Secrets; `KOPIA_SFTP_PASSWORD` nicht unterstützt | Mit temporärem Loopback-Test reproduziert; Bericht `SPIKE-D-SECRETS.md`, Fixture `secrets-report.json`. Sicherheitsinvariante bleibt bestehen; sichere Zuführung vor Remote-Produktionsintegration noch zu lösen |
| 2026-10-23 | Folge-Spike D: S3 öffnet ohne Credential-Felder über AWS-Environment; WebDAV öffnet via anonymer Config-Pipe und erstellt/restauriert Backups | CLI/TLS-Server, falsche S3-Secrets/Tokens und EOF-Shutdown geprüft. Kein Secret-Persistieren in diesen Abläufen; neuer Remote-Bootstrap, Wiederverbindung und Swift-Integration bleiben offen. Keine Ausnahme der Sicherheitsinvarianten |
| 2026-10-23 | WebDAV-Spike: `--create-only` ohne lokale Secret-Datei; Policy/Owner explizit setzen; Pipe über schreibgeschützten Symlink-Pfad mit gemeinsamer Wartungssperre | Anlegen, schnelle Wartung, Backup/Restore und Crash-Neustart geprüft. Reiner `/dev/fd`-Pfad scheitert bei `.mlock`; fehlende Cache-Kapazitäten können Kopia-Panic auslösen. Produktionsübernahme der Pipe-Übergabe als Präzisierung von AGENTS.md §2.4 noch nicht beschlossen |
| 2026-10-23 | WebDAV-Laufzeitkonfiguration über explizit vererbte anonyme Pipe freigegeben | Nutzerbestätigung: Secrets dauerhaft nur im Schlüsselbund, JSON nur im Speicher; frische Pipe, geschützter Symlink-Pfad, gemeinsame Wartungssperre und Cleanup verbindlich. Keine reguläre Secret-Datei und keine Kopia-Konfigurations-Schreiboperationen; AGENTS.md §2.4 und §6.2/§8 präzisiert |
| 2026-10-23 | Lokale Builds führen vorerst keine expliziten Signierschritte aus (`CODE_SIGNING_ALLOWED=NO`) | Nutzer stellt Signierung bis spätere Releases zurück; Fetch-/Embed-Skripte respektieren dies ebenfalls. Hardened-Runtime-Konfiguration und XPC-Signaturprüfung bleiben bestehen; vor Releases explizit aktivieren |
| 2026-10-23 | Native URLSession prüft Leaf-Pin, exakten Zertifikat-Anker und SSL-Policy für 127.0.0.1; Kopia-Start mit `--tls-generate-cert-valid-days=365` | Kopia 0.23.1 erzeugt standardmäßig Zertifikate für 3650 Tage; macOS lehnt diese mit Security-Code -67901 ab. 365 Tage gegen echten Server erfolgreich, keine Trust-Ausnahmen/ATS-Lockerung. Async-Bytes-Tasks bekommen den Delegate explizit; CSRF und Cookie nur im Speicher |
| 2026-10-23 | Speicherziel-Metadaten mit Validierung vor JSON-Encoding; SFTP-Authentifizierung nur als Schlüsselbund-Referenzen und SHA256-Host-Key-Pin modellieren | Präzisierung von §7.1 gemäß Secret-Invariante; kein privater Schlüssel als Config-/Datei-Payload. Keine Remote-Verbindung, Host-Key-Bestätigung oder produktive SFTP-Zuführung allein durch gültige Metadaten; WebDAV-/S3-Credential-Zuordnung folgt mit Engine |
| 2026-10-23 | Lokale Rechte-/Kapazitätsprüfung ohne Schreibprobe und gemeinsame Engine-Operationssperre ergänzt | §9: dezimale GB und strikte Schwellen; Sperre gilt während Cleanup auch bei Abbruch. Bausteine noch ohne Agent-/Queue-Anbindung; keine Startfreigabe allein durch einzelne Teilprüfung. |
| 2026-10-23 | Binary-Version und Backup-Passwort werden als erste zwei Preflight-Schritte frisch geprüft | §9: isolierte begrenzte Versionsabfrage ohne Secrets, danach nur lesender Schlüsselbundzugriff; keine Secret-Payload im Ergebnis und keine Freigabe allein durch diese Teilprüfung. Gepinnte Version wird explizit aus der bestehenden Konfiguration geliefert, nicht als zweiter Versionspin eingeführt. |
| 2026-10-23 | Preflight-Bausteine als geordneten Diagnoseablauf mit typisiertem Bericht verbinden; Sperre bereits vor Adapterzugriff reservieren | §9: fachliche Reihenfolge unter Reservierung, Busy endet sofort; unbekannter FDA-/Remote-Zugriff blockiert, fehlende Quellen/Laufbedingungen überspringen. Bericht ist keine Startfreigabe, Diagnose gibt Sperre bei Rückkehr frei; produktiver Lifecycle bleibt offen. |
| 2026-10-23 | Frische Energie-/Netzwerkabfragen als Standard für Preflight-Schritt 8 | §9: IOKit-Power-Sources und NWPathMonitor-AsyncSequence ohne Cache; fünf Sekunden bis zur ersten Pfadbeobachtung, sonst unbekannt. Abbruch bereinigt Beobachter; kein Erreichbarkeits-/SSID-/FDA-Nachweis und noch keine kontinuierlichen Trigger-Monitore. |
| 2026-10-23 | Reservierte Operationsgrenze mit frischer Wiederprüfung und verpflichtendem Live-Schutz ergänzt | §9: Sperre bis nach Operations-/Monitor-Cleanup halten, nach Aktivierung des Schutzes erneut prüfen und Identitäten unmittelbar vor Callback prüfen; fehlender Schutz verweigert Start. Noch keine produktive Kopia-/Agent-Anbindung, Schutzadapter aktuell nur in Tests. |
| 2026-10-24 | Nativen lokalen Volume-Schutz über DiskArbitration als expliziten Adapter ergänzt; APFS-Gerät per statfs auflösen | §9: lokale UUID-/Mountbestätigung, Unmount-Veto, terminale Verlustereignisse und Cleanup unter bestehender Reservierung; schwache Callback-Kennungen verhindern späte Zeigerzugriffe. Neu verfügbare ungeschützte Quellen/Netzwerk-Volumes blockieren; Agent-/Benachrichtigungs-UX und echte Eject-Abnahme offen. |
| … | *(Spike-Ergebnisse aus Phase 0 hier eintragen)* | |

---

## Anhang A – Beobachtung auf dem Entwicklungsrechner

Auf dem Entwicklungsrechner existiert bereits eine Kopia-Standardkonfiguration mit einem Dateisystem-Repository unter
`/Volumes/TRESOR` (Laufwerk zum Zeitpunkt der Analyse nicht verbunden). Konsequenzen:
- MacKopia darf diese Konfiguration **nie** verändern (eigene `--config-file`-Pfade, Abschnitt 5.1).
- Der Import-Assistent (Phase 4) muss genau diesen Fall abdecken: bestehende Config erkennen, Repository-Parameter übernehmen,
  Passwort abfragen (ggf. aus Kopias eigenem Keychain-Eintrag – nur nach Nutzerzustimmung), Volume-UUID beim nächsten Anstecken binden,
  bestehende Snapshot-Identität (`user@host`) übernehmen, damit die Historie nahtlos weiterläuft.
- Gutes reales Testszenario für Phase 4/6.
