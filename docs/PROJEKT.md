# MacKopia – Projektbeschreibung & Umsetzungsleitfaden

> **Arbeitstitel:** MacKopia · **Status:** Spezifikation v2.0 · **Stand:** 2026-10-25
> **Zielgruppe dieses Dokuments:** Coding-Agents und Entwickler, die integrierte Produktphasen umsetzen.
> Dieses Dokument ist die **verbindliche Quelle** für Architektur, Entscheidungen und Abnahmekriterien.
> Abweichungen werden hier dokumentiert (Abschnitt 17 „Entscheidungslog“), nicht stillschweigend im Code.
> **Neustarteinstieg:** [STATUS.md](STATUS.md), [IMPLEMENTIERUNG.md](IMPLEMENTIERUNG.md), dann §14
> und die relevanten Fachabschnitte. Aktuell: Phase 1, Package-Fundament vorhanden, produktive lokale Verdrahtung offen.
> Vollständige Vorgeschichte nicht als Startkontext laden.

---

## 0. Kurzfassung

MacKopia ist eine native App mit aktuellem Swift und SwiftUI, ausschließlich für macOS 27 auf Apple Silicon, die [Kopia](https://kopia.io) als
Backup-Engine nutzt und daraus ein **Time-Machine-einfaches, Arq-zuverlässiges** Backup-Produkt macht:

- **Backup-Pläne**: Mehrere Pläne mit eigenen Quellen, Zielen, Zeitplänen, Aufbewahrungsregeln und Ausschlüssen.
- **Ziele**: Lokal/USB/Thunderbolt, NAS per SMB, SFTP, WebDAV, S3-kompatibel (AWS, B2, Wasabi, MinIO).
- **Automatik**: Zeitplan, „Laufwerk angeschlossen“, „NAS erreichbar“, mit Bedingungen (Netzteil, kein teures Netz).
- **Robust**: Hintergrund-Agent (läuft ohne geöffnetes Fenster), Selbstheilung, Vorabprüfungen, Integritätsprüfung.
- **Sicher**: Passwort ausschließlich im Schlüsselbund, verschlüsselte lokale Kopia-API mit Zertifikats-Pinning,
  signierte XPC-Kommunikation, Wiederherstellungs-Kit.
- **Wiederherstellen**: Finder-artiger Snapshot-Browser, Quick Look, Wiederherstellen einzelner Dateien oder ganzer Ordner.
- **Vertrieb**: außerhalb des App Store ohne Apple-Konto, lokale Ad-hoc-Signaturen und bewusste Gatekeeper-Freigabe; Auto-Updates via Sparkle 2, Kopia-Binary im Bundle mitgeliefert.
- **Sprachen**: Deutsch (Primär) + Englisch über String Catalog.

---

## 1. Korrekturen & Präzisierungen gegenüber dem ursprünglichen Prompt

| Ursprüngliche Idee | Entscheidung | Begründung |
|---|---|---|
| macOS 15 „Golden Gate“ | **Ausschließlich macOS 27, natives arm64** | Nutzerentscheidung 2026-10-25: keine Alt-OS-/Intel-/Rosetta-Kompatibilität; aktuelle SDK-Anbindungen direkt nutzen. |
| `/opt/homebrew/bin/kopia` nutzen | **Kopia im App-Bundle mitliefern** (`Contents/Helpers/kopia`), lokal ad-hoc signiert, Version festgelegt | Reproduzierbar, kein Homebrew-Update kann die App zerstören, keine Abhängigkeit von der Installation. Eigener Pfad nur als „Experten“-Option. |
| Ein `BackupManager` als zentrales `@Observable` | **Schichtenarchitektur**: Engine im Agent (Actors), UI-State als kleine `@Observable`-Stores pro Feature | Ein Gott-Objekt skaliert nicht und ist nicht testbar. Backups müssen ohne UI laufen. |
| Nur `Process` + stdout parsen | **Hybrid**: privater `kopia server` (REST/JSON) für Snapshots, Fortschritt, Browsing, Restore; direkte CLI-Aufrufe mit `--json` für Einrichtung/Wartung | Strukturierter Fortschritt statt fragilem Text-Parsing (so macht es auch KopiaUI). |
| „Pause“ hält den Prozess an | **Pause = sauberer Abbruch mit Checkpoint; Fortsetzen = neuer Lauf, der dank Deduplizierung bereits Übertragenes überspringt** | Kopia kennt kein echtes Pausieren. `SIGSTOP` führt bei Netzwerkzielen zu Timeouts. Kopias inhaltsadressierter Speicher macht Neustarts billig. |
| „Stop ohne Datenkorruption“ | Abbruch über die Kopia-API (`sources/cancel`), Eskalation SIGINT → SIGTERM → SIGKILL nur als Notfall | Kopia schreibt Content-Blobs unveränderlich und das Snapshot-Manifest erst am Ende. Ein Abbruch korrumpiert das Repository nie, er hinterlässt höchstens einen „unvollständigen“ Snapshot. |
| Passwort-Feld mit Autofill (Enpass) | `SecureField` mit `.textContentType(.password)` bzw. `.newPassword`, Einfügen per ⌘V, Speicherung **nur im Schlüsselbund** | Funktioniert mit macOS-Passwörter-App und mit Enpass (Autofill/Einfügen). Passwort niemals in UserDefaults, Dateien, Logs oder argv. |
| Sandbox deaktivieren | **App Sandbox aus, Hardened Runtime an**, Festplattenvollzugriff (FDA) per Onboarding | Vertrieb außerhalb des Mac App Store ohne Apple-Konto; lokale Ad-hoc-Signaturen und Hardened Runtime bleiben Pflicht. |
| Laufwerk „im Hintergrund prüfen“ (Polling) | **Ereignisgesteuert**: `NSWorkspace`-Mount-Notifications + DiskArbitration, Identifikation über Volume-UUID | Kein Polling, keine Verwechslung bei gleichen Volume-Namen. |

---

## 2. Lehren aus führenden Backup-Lösungen (nicht das Rad neu erfinden)

| Vorbild | Übernommenes Prinzip | Umsetzung in MacKopia |
|---|---|---|
| **Time Machine** | Null-Konfiguration, „angesteckt = gesichert“, Status in der Menüleiste, Auswerfen blockieren während eines Backups | Onboarding mit sinnvollen Vorgaben; Trigger „Laufwerk verbunden“; DiskArbitration-Unmount-Approval; Menüleisten-Status mit „Letztes Backup: vor 12 Min.“ |
| **Arq** | Getrennter Hintergrund-Agent, Backup-Pläne, regelmäßige Validierung, E-Mail/Notification-Berichte, „Pause für 1 Stunde“, Wiederherstellungs-Kit | Agent via `SMAppService`; Plan-Modell; geplante `snapshot verify`-Läufe und Test-Restores; Pause mit Dauer; PDF-Recovery-Kit |
| **Backblaze** | Sorglos-Modus, sehr klare Warnungen („Seit 14 Tagen nicht gesichert“) | Gesundheitsampel pro Plan mit Schwellwerten und Mitteilungen |
| **Vorta (Borg-GUI)** | Profile, Keychain-Speicherung, Bedingungen (Netzteil, WLAN-Liste, keine teuren Netze), Pre-/Post-Skripte | Ausführungsbedingungen pro Plan; Hook-Skripte (Version 2, optional) |
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

- APFS-Snapshots als konsistente Quelle (benötigt privilegierten Helper für `mount_apfs -s`) → Version 2.
- Pre-/Post-Hook-Skripte (Kopia-Actions) → Version 2.
- Kopia-Repository-Server (Multi-User), Google Drive, Azure, rclone → bei Bedarf.
- Mount eines Snapshots im Finder (`/api/v1/mounts`, WebDAV) → Version 2 (nice to have).
- iOS/iPadOS-Companion, Widgets, App Intents/Kurzbefehle → Version 2 (App Intents sind jedoch einfach und empfohlen).

---

## 4. Technologie-Stack & Rahmenbedingungen

| Bereich | Festlegung |
|---|---|
| Sprache | Neuester stabiler Swift-Compiler der Xcode-Toolchain (aktuell 6.4), **Strict Concurrency = complete**, Swift-6-Sprachmodus |
| UI | Aktuelles SwiftUI aus dem macOS-27-SDK, AppKit nur gezielt (`NSOpenPanel`, `QLPreviewPanel`, `NSWorkspace`) |
| Isolation | App-Targets: `Default Actor Isolation = MainActor` (Approachable Concurrency). Pakete: nonisolated by default, explizite Actors |
| Zielplattform | Nur macOS 27.x, Deployment Target 27.0, natives arm64; keine Intel-/Rosetta-/Alt-OS-Matrix |
| Build | Neueste stabile Xcode-Version (aktuell 27.1), macOS-27-SDK, mit App-Target + Agent-Target; **gesamte Logik in lokalem Swift Package** `MacKopiaKit` |
| Tests | Swift Testing (`@Test`, `#expect`), XCUITest für Smoke-Tests, Integrationstests gegen echtes Kopia |
| Persistenz | Konfiguration: versioniertes JSON (Codable, atomare Writes). Historie: SQLite via **GRDB** (Migrationen) |
| Logging | `os.Logger` (Subsystem `<bundle-id>`, Kategorien pro Modul), Kopia-Logs in eigenem Log-Verzeichnis |
| Abhängigkeiten | **Nur**: Sparkle 2, GRDB. Optional `swift-subprocess` (swiftlang), wenn ≥ 1.0 verfügbar; sonst eigener `Process`-Wrapper |
| Signierung / Vertrieb | Außerhalb des App Store, ohne Apple-Developer-Konto; lokale Ad-hoc-Signaturen und Hardened Runtime. Keine verpflichtende Developer ID oder Notarisierung; bewusste Gatekeeper-Freigabe durch den Nutzer |
| Lizenz Kopia | Apache 2.0 → `LICENSE`/`NOTICE` von Kopia im Bundle und im „Über“-Fenster |

Die jeweils neueste stabile Toolchain wird am Anfang eines größeren Arbeitsblocks geprüft und
als reproduzierbarer Stand festgehalten; keine automatische Beta-/RC-Installation. SwiftUI gehört zum
SDK, nicht zu einer separat versionierten Abhängigkeit. Swift 6 ist der Sprachmodus, 6.4 der Compilerstand.
Aktuell nachgewiesen: Xcode 27.1 (27A9275), Swift 6.4, macOS-27-SDK.
Quellen: [Apple Xcode](https://apps.apple.com/us/app/xcode/id497799835),
[Apple macOS-27-Kompatibilität](https://support.apple.com/en-us/127455).
Die aktuelle Support-/Testmatrix enthält nur macOS 27; keine künstliche Laufzeitsperre für spätere
macOS-Versionen. Eine Erweiterung der offiziell geprüften Matrix ist eine bewusste spätere Entscheidung.

**Bundle-IDs (vorerst bestätigte Platzhalter):**
- App: `com.example.MacKopia`
- Agent: `com.example.MacKopia.Agent`
- XPC-Mach-Service: `com.example.MacKopia.Agent.xpc`
- Keychain: ausschließlich Hintergrunddienst; keine Team-ID-/Shared-Access-Group-Voraussetzung (§8).

---

## 5. Systemarchitektur

### 5.1 Prozessmodell

```
┌──────────────────────────────┐        XPC (Mach-Service,         ┌─────────────────────────────────────┐
│  MacKopia.app  (UI)          │  ◄──── Peer-Requirement: ──────►  │  MacKopia Agent.app  (LSUIElement)  │
│  • Hauptfenster (Setup,      │        pinned code hash)              │  • Engine (Scheduler, Trigger,      │
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
│   ├── Secrets/           # agentverwalteter Login-Keychain (keine Team-ID/Access Group), SecretRef
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
│   └── Resources/Localizable.xcstrings
├── Agent/                               # Target "MacKopia Agent"
│   ├── AgentApp.swift                   # @main, MenuBarExtra, startet Engine + XPC-Listener
│   ├── XPCServer/                       # Listener, Peer-Prüfung, Request-Routing
│   ├── MenuBar/
│   ├── LaunchAgent/Agent.plist            # Build-Template; Name/Identitäten aus App-Bundle-ID
│   └── Resources/Localizable.xcstrings
├── Scripts/
│   ├── fetch-kopia.sh                   # lädt gepinnte Kopia-Version, prüft SHA256, übernimmt ausschließlich geprüftes arm64-Binary
│   ├── embed-kopia.sh                    # lokale Ad-hoc-Signaturen und Agent-Plist
│   └── make-appcast.sh                   # geplant in Phase 6
├── Config/
│   ├── kopia-version.json               # { "version": "0.23.1", "sha256": { "arm64": "…", "amd64": "…" } }
│   ├── Shared.xcconfig, Debug.xcconfig, Release.xcconfig
└── .github/workflows/ci.yml
```

Bundle-Layout der fertigen App:
```
MacKopia.app/Contents/
├── MacOS/MacKopia
├── Helpers/kopia                                  # ad-hoc signiert, Hardened Runtime
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
- `Scripts/fetch-kopia.sh` (Build-Phase, gecacht): lädt das offizielle Release-Archiv für `darwin-arm64`
  von GitHub, **verifiziert SHA256 gegen die gepinnten Werte**, übernimmt ausschließlich das geprüfte native arm64-Binary
  und signiert lokal ad-hoc mit `codesign --sign - --options runtime`, ohne Apple-Konto oder Timestamp-Dienst.
  App und eingebetteter Agent erhalten ebenfalls lokale Ad-hoc-Signaturen; `CODE_SIGNING_ALLOWED=YES`,
  manuelle Identität `-`, leere Team-ID und keine automatisch injizierten Basis-Entitlements.
  `--options runtime` wird explizit gesetzt, weil Xcode bei Ad-hoc-Identität die Runtime-Option
  sonst trotz `ENABLE_HARDENED_RUNTIME=YES` auslässt. Xcodes separate Debug-Dylib ist deaktiviert:
  Sie lässt sich ohne gemeinsame Team-ID unter Library Validation nicht laden.
  Ohne passenden Download-Hash bricht der Build ab.
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

S3-Produktionspfad (Phase 4): `repository create s3 --create-only` erhält AWS-Zugangsdaten nur über
Environment. Danach erzeugt der Agent atomar eine isolierte 0600-Verbindungsdatei mit einer exakten
Storage-Allowlist ohne `accessKeyID`, `secretAccessKey` oder `sessionToken`. Cache-Kapazitäten explizit setzen;
Balanced/zstd und Wartungs-Owner nach Create separat initialisieren. Connect liest Status/Owner, beansprucht
nur einen bislang leeren Owner und übernimmt fremde Owner unverändert. Passwort und AWS-Werte liegen als
begrenztes Envelope gemeinsam unter `Repository.secretRef` im Schlüsselbund, nie in App-Konfiguration/Events.
Vor Backup sowie Credential-Ersatz erfolgen Status und ein frischer Format-Blob-Read; Cache-Evidenz allein
bestätigt keinen Zugang. Ersatz-Credentials erst nach erfolgreicher Probe speichern. HTTPS ist verbindlich;
HTTP wird nur für literales `127.0.0.1` zum lokalen Test zugelassen, keine allgemeine TLS-Ausnahme.
Object-Lock-Einrichtung bleibt bis zu einem eigenen Backend-Nachweis außerhalb dieses Assistenten.

WebDAV-Produktionspfad (Phase 4): `repository create webdav --create-only` erhält WebDAV-Zugänge nur über
Environment; es wird keine lokale Verbindung geschrieben. Connect besteht aus frischer Pipe-Konfiguration,
Status-/Format-Blob-Probe und Owner-Prüfung, ohne `repository connect`. Backup-Passwort, WebDAV-Benutzername
und -Passwort liegen als begrenztes Envelope gemeinsam unter `Repository.secretRef` im Schlüsselbund.
Die vollständige Laufzeitkonfiguration wird pro Operation aus validiertem Ziel und frisch gelesenem Envelope
nur im Speicher aufgebaut; jeder CLI-/Server-Start bekommt eine eigene Pipe über den bestehenden
Symlink-/Lock-Transport. Balanced/zstd und Owner werden nach Create ausdrücklich initialisiert; fremde Owner
bleiben unverändert. Credential-Ersatz erst nach Status und frischem Format-Blob-Read speichern.
HTTPS ist verbindlich; HTTP ausschließlich für literales `127.0.0.1` im lokalen Fixture.

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

Kopia 0.23.1 kann beim Control-Shutdown den Prozess beenden, bevor die HTTP-Antwort vollständig gesendet ist.
Ein Transportfehler bleibt im Client ein Fehler; er ist allein kein Erfolgsnachweis. Der echte Integrationstest verlangt
deshalb zusätzlich das beobachtete Ende des eigenen Kindprozesses mit Exit 0, ohne dafür stdin zu schließen oder Signale
zu senden. Der primäre produktive Shutdown-Pfad bleibt stdin-EOF mit anschließendem Reaping.

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

Die isolierte Queue-/Runner-Steuerung unterstützt bereits Plan- und globale Pause mit optionalem Endzeitpunkt,
Fortsetzen und planbezogenen Stopp. Pause hält bestehende wartende Aufträge und weist neue Trigger
mit einem festen `planPaused`-Fehler ab. Überlagerte globale/individuelle Pausen wirken gemeinsam;
Aufheben einer Pause hebt die andere nicht auf. Entnahme, Task-Erzeugung und Registrierung des
Abbruchs geschehen in einem Queue-Actor-Schritt. Der Runner propagiert auch Aufruferabbruch an
diesen Task und wartet weiterhin Cleanup/Historie ab. Externe Pause-/Stopp-Aufrufe warten auf
registrierte Ausführungen; ein Aufruf aus der eigenen Ausführung wartet nicht auf sich selbst.
Fortsetzen merkt während laufender Bereinigung nur den Wiederaufnahmewunsch vor und reiht
unterbrochene Arbeit erst nach bestätigtem Cancellation-Abschluss neu ein; bereits erfolgreich
abgeschlossene Arbeit wird nicht allein wegen einer Pause während des Historienabschlusses wiederholt.
Stopp entfernt Folgeaufträge und Wiederaufnahmewünsche, erhält aber eine bereits explizite Pause.
Neue Einreihungen durchlaufen beim Start wieder den aktuellen ConfigStore und alle Schutzprüfungen.
Ein injizierter monotoner Timer hebt nur die zugehörige Pause zum absoluten `until`-Zeitpunkt auf.
Er wird vor suspendierender Bereinigung scharfgeschaltet; Ablauf während Bereinigung merkt die
Wiederaufnahme nur vor. Ersetzen/manuelles Fortsetzen cancelt und joint alte Timer; eine eindeutige
Kennung verhindert veraltete Zustellungen. `BackupPauseOption` berechnet eine Stunde, morgen 08:00
im injizierten Kalender (auch über Sommer-/Winterzeitwechsel) oder unbegrenzt. Ein bereits gewählter
Endzeitpunkt bleibt bei Zeitzonenwechsel absolut. Bei zurückgestellter Wanduhr wird vorzeitig ausgelöster
Timer neu angesetzt; `reconcilePauses` gleicht Wake-/Uhrzeitänderungen ab. `AutomaticBackupRuntime` ruft diesen Abgleich bei Wake-/Uhrzeitereignissen auf. Timerfehler und explizites Ende der Timer-Überwachung lassen die Pause
als `timerUnavailable(until:)` sichtbar bestehen; nur explizites Fortsetzen/Ersetzen hebt sie dann auf.
Die Package-Laufzeit speichert Plan- und globale Pausen vor der wirksamen Steueränderung in
`pauses.json` neben der Konfiguration. `BackupPauseStore` verwendet dieselbe private 0700-Ablage,
0600-Dateien, Symlink-/Hardlink-Abweisung, gemeinsame Dateisperre und atomaren fsync-/Rename-Pfad
wie `ConfigStore`. Versioniertes Dokument mit höchstens 4097 eindeutigen Scopes; ausschließlich
Plan-UUID, unbegrenzte Pause/absoluter Endzeitpunkt bzw. Timerfehlerstatus, keine Pfade oder Secrets.
Jede Laufzeit besitzt einen separaten Byte-Vergleichsstand; externe Änderungen verhindern Überschreiben.
Lesefehler, ungültige Dokumente und unbekannte Versionen verhindern den Start statt leere Pausen anzunehmen.
Vor Trigger-/Engine-Aktivierung werden Pausen geladen; entfernte Plan-UUIDs und bereits abgelaufene
normale Zeitpausen werden dauerhaft entfernt. Timerfehlerpausen bleiben auch nach ihrem ursprünglichen
Endzeitpunkt manuell lösbar. Fortsetzen und automatischer Ablauf schreiben vor der Queue-Freigabe.
Ein Schreibfehler verriegelt Aufnahme und Entnahme; die Laufzeit beendet aktive Arbeit über den normalen
Abbruch-/Cleanup-/Historienpfad und meldet ausschließlich `controlStateUnavailable`. Beim fehlgeschlagenen
Speichern bleibt der letzte dauerhafte Stand maßgeblich; ein korrigierter Speicher wird erst mit einer
neuen Laufzeitinstanz wieder geöffnet. Shutdown erzeugt keine dauerhafte globale Pause und ersetzt
keine gespeicherten Zeitpausen durch den rein lokalen Timer-Shutdownstatus.
Schema 2 derselben Datei ergänzt wartende/aktive/unterbrochene Aufträge (höchstens 8192, eindeutige
Laufkennungen und höchstens ein wartender sowie ein aktiver/unterbrochener Auftrag je Plan).
Schema 1 wird im Speicher mit leerer Arbeit gelesen, beim nächsten Write als Schema 2 gesichert;
ältere Clients lehnen Schema 2 ab. Pausenänderungen erhalten gespeicherte Arbeit und umgekehrt.
Nur Lauf-/Plan-/Ziel-UUID, Trigger, Anforderungsdatum und Status, keine Quellpfade oder alten Mount-/TCP-
Nachweise. Aufnahme und Entnahme werden vor weiterer Ausführung gesichert, Stopp entfernt dauerhafte
Absicht vor dem Abbruch. Jede Queue-Mutation wird synchron unter der bestehenden atomaren Ablage
gesichert; Schreibfehler sperren weitere Aufnahme/Entnahme und führen zum Runtime-Shutdown.
Beim Neustart werden passende Aufträge anhand der aktuellen aktivierten Pläne, Ziel-UUID und noch
konfigurierten Trigger zusammengefasst und mit neuen Laufkennungen eingeordnet. Pausen bleiben wirksam;
Fortsetzen gibt diese Arbeit frei. Abgelaufene Zeitpausen halten sie nicht weiter auf. Wiederanlauf wartet
mindestens zwei Minuten und bis nach der Login-Sperre; währenddessen bleibt Queue-Entnahme gesperrt.
Jede tatsächliche Ausführung durchläuft wieder ConfigStore, UUID-/Zugriffs-/Netzwerkprüfungen und den
geschützten Engine-Pfad. Historisch abgeschlossene Erfolge/Warnungen/Fehler/Skips werden nicht wiederholt;
gespeicherte Cancellation-Absicht darf hingegen nach Pause/Shutdown fortgesetzt werden. Bei Shutdown
wird Persistenz vor Worker-Abbruch getrennt, damit die letzte Absicht ohne neue globale Pause erhalten bleibt.
Retry-Ketten und noch nicht angenommene Trigger-Evidenz bleiben flüchtig. Agent-/XPC-Steuerung ist über den gemeinsamen Dienstpfad in §7.5 verdrahtet.
Die gemeinsame Package-Laufzeit wird in §7.5 beschrieben. Niedrigstufige `takeNext`-Aufrufer ohne registrierten Task
bleiben selbst für Abbruch/Bereinigung verantwortlich; die Engine verwendet den registrierten Runner.

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
                     lowPriority: Bool; uploadLimitMbps: Double?; ejectVolumeAfterBackup: Bool
                     plausibilityDropPercent: Int /* 1–100, Standard 50 */ }
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
gesetzt (idempotent, vor jedem Lauf frisch abgeglichen). Ein Plan-Hash allein genügt nicht: vererbte Policies und
aufgelöste Ausschlüsse können sich unabhängig davon ändern. Gehören zwei Pläne zur gleichen
Quelle im selben Repo, ist das ein Validierungsfehler im Editor (sonst würden sich die Policies überschreiben).

Der native Serverclient liest quellbezogene Definitionen mit `GET /api/v1/policy` und berechnet die effektive
Policy mit `POST /api/v1/policy/resolve`. Beide verlangen die vollständige Identität `userName`/`host`/`path`
und verwenden denselben gepinnten TLS-/CSRF-Transport wie die übrigen Lesezugriffe. Der POST-Body ist fest
auf `numUpcomingSnapshotTimes: 0` begrenzt. Der reine Lesepfad enthält keine `updates`; der Schreibabgleich
kann zusätzlich eine vollständige lokale Definition als `updates` zur nichtpersistierenden Vorschau senden.
Keiner der Pfade setzt Kopia-Zeitpläne.
Kopia 0.23.1 meldet eine fehlende Definition mit HTTP 400 und Code `NOT_FOUND`; ausschließlich diese Kombination
beim Definitionsabruf ergibt `nil`. Andere Fehler und übergroße Antworten bleiben Fehler. Typisierte, nur
decodierbare Projektionen lesen Aufbewahrung, Dateiregeln, Kompression sowie deren Vererbungsursprünge;
fehlend, null, 0 und false werden nicht durch vermeintliche Standardwerte ersetzt. Globale Ursprünge dürfen
leere Identitätskomponenten enthalten. Unbekannte Felder werden ignoriert; diese unvollständigen Projektionen
dürfen niemals zum Zurückschreiben einer Policy verwendet werden. Ein vollständiger lokaler Policy-Merge-Baustein
ist separat verfügbar; der explizite Engine-Schreibabgleich ist unten beschrieben. Die Agent-Anbindung bleibt
offen; kein automatisches Anwenden oder Löschen von Backups in diesem Lesepfad.

`PolicyTranslator` übersetzt rein und deterministisch die planverwalteten Werte für eine vollständig im Plan
enthaltene Quelle: Aufbewahrung einschließlich nil/0, Kompression, Ausschlussmuster, Cache-Verzeichnisse,
Dateigrößenlimit (dezimal MB → Int64-Bytes, überlaufgeprüft) und Dateisystemgrenze. Das Ergebnis ist bewusst
kein serialisierbarer Kopia-Schreibbody. Vererbungssteuerung und Erhalt fremder Policy-Felder gehören zum
separaten Schreibabgleich. Aktivierte macOS-/Time-Machine-Ausschlussquellen verlangen explizit für diese Quelle
aufgelöste Musterlisten; nil ist unaufgelöst und blockiert, eine leere Liste ist ein gültiges Ergebnis ohne Treffer.
Die macOS-Standardliste ist als rein lexikalischer Baustein und der Time-Machine-Resolver als expliziter
Dateisystemadapter verfügbar und im expliziten `SourcePolicySynchronizer` verbunden; die Agent-Anbindung
bleibt offen. Reihenfolge: macOS, Time Machine, benutzerdefinierte Muster; keine Sortierung oder Deduplizierung, damit Negationen und wiederholte Regeln erhalten bleiben. Für die kombinierte Liste gelten
dieselben Größen-/Textgrenzen wie für gespeicherte Muster. Keine I/O-, Scheduling- oder Löschaktion.

`policyDefinition(source:)` liest zusätzlich die vollständige lokale Definition über denselben gepinnten
GET-/CSRF-Transport und liefert sie zusammen mit der exakten angefragten Quellidentität. Nur HTTP 400 +
`NOT_FOUND` bedeutet eine fehlende Definition; ungültige/mehrdeutige Dokumente bleiben Fehler. Das 1-MiB-Limit
gilt bereits beim Einlesen, sowohl mit Content-Length als auch bei gestreamten Antworten. Das Ergebnis ist
eine Momentaufnahme ohne Revisionstoken; es erlaubt keinen späteren unbedingten Schreibzugriff. Keine
Policy-Änderung oder effektive Freigabe in diesem Lesepfad.

`KopiaPolicyDocument` im Modul `KopiaServer` hält die vollständige lokale JSON-Definition (maximal 1 MiB, Tiefe 64),
einschließlich unbekannter Werte und ursprünglicher Zahlentokens. `SourcePolicyMerger` ersetzt ausschließlich
planverwaltete Felder und erhält übrige Felder sowie bestehende Scheduling-Werte unverändert. Retention-nil
entfernt den lokalen Override, 0 bleibt explizit. Der Baustein führt keine HTTP-Schreibzugriffe aus und bestätigt
keine effektive Policy: Kopia 0.23.1 erbt leere Ignore-Listen und maxFileSize 0 weiterhin, unabhängig von
`noParentIgnore`; dieses Flag beeinflusst die Verzeichnistraversierung. Root-`noParent` bleibt unverändert,
damit fremde Vererbung erhalten bleibt. Der Writer prüft effektive Regeln und deaktiviertes
Kopia-Scheduling zusätzlich. Reine lokale Idempotenz ersetzt diesen Nachweis nicht.

`SourcePolicySynchronizer` führt innerhalb einer geschützten Repository-Operation den vollständigen
quellbezogenen Abgleich aus: frische optionale macOS-/Time-Machine-Auflösung → vollständige Definition
lesen → lokale Definition mergen → effektive Vorschau mit `updates` → Sollwerte und inaktives Scheduling
prüfen → Vorschau und lokale Definition erneut lesen → bei Bedarf `PUT /api/v1/policy` → gespeicherte
Definition und tatsächlich effektive Policy erneut prüfen. Ein zweiter identischer Abgleich schreibt nicht.
Retention-nil erbt weiterhin; explizite 0/false bleiben erhalten. Leere Ausschlüsse bzw. fehlendes Größenlimit,
die durch Vererbung nicht wirksam werden, blockieren vor dem Schreiben. Scheduling wird weder gesetzt
noch entfernt; vorhandene aktive Zeitpläne blockieren. Time-Machine-Ergebnisse müssen auch unmittelbar
vor dem Schreiben und bei Abschluss noch quellgebunden und höchstens 60 Sekunden alt sein.

Ein Synchronizer gehört zu genau einer Repository-Sitzung; parallele Aufrufe derselben Instanz werden
abgewiesen. Der Aufrufer hält die vorhandene Repository-/Volume-Reservierung und verhindert weitere
MacKopia-Schreibzugriffe bis zum Ende. Kopia 0.23.1 bietet jedoch keinen bedingten PUT, ETag oder
Revisionstoken: erneute Leseprüfungen erkennen beobachtete lokale und effektive Änderungen, sind aber
keine atomare Sperre gegen externe Kopia-Clients. Nachprüfungen dürfen keine automatische Rückschreibung
oder blinde Wiederholung auslösen. Fehler/Abbruch während oder nach PUT bedeuten gegebenenfalls einen
ungeklärten Schreibausgang; vor dem nächsten Versuch wird frisch gelesen. Fremde JSON-Felder bleiben
im übertragenen Dokument erhalten; verwirft der gepinnte Server unbekannte Felder, schlägt die
Definitionsnachprüfung fehl. Es gibt keine Zusage, dass Kopia unbekannte Erweiterungen persistiert.
Der Abgleich startet selbst keine Snapshots und führt keine Aufbewahrungs-/Löschaktion aus.
Der explizite manuelle Engine-Pfad (§7.5) ruft ihn vor Uploads auf; die Der manuelle Dienstpfad ist über `LocalBackupService` verdrahtet; die automatische Agent-Runtime folgt in Phase 2.

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
`currentConfiguration()` liefert ausschließlich den letzten erfolgreich geladenen/gespeicherten Actor-Stand;
vor dem Laden und im Sicherheitsmodus ist Lesen gesperrt. Externe Dateiveränderungen werden weiterhin
beim Laden/Speichern erkannt, nicht durch jeden In-Memory-Lesezugriff. Export/Import sowie UI-/Agent-Anbindung folgen separat.

### 7.3 Scheduler

- Single Source of Truth: `Scheduler` (Actor) berechnet für jeden Plan `nextRunDate` aus den Triggern.
- Ein Timer auf das jeweils nächste Datum (`Task.sleep(until:)` mit `ContinuousClock` **plus** Neuberechnung bei
  `NSWorkspace.didWakeNotification`, Zeitzonen- und Uhrzeitänderung `NSSystemClockDidChange`), da Timer im Ruhezustand nicht feuern.
- **Nachholen** (anacron-Prinzip): Nach dem Aufwachen oder Agent-Start werden verpasste Läufe einmal nachgeholt
  (nicht n-fach), mit 2 Min. Verzögerung, damit Netzwerk und Volumes bereit sind.
- Jitter ±60 s für Intervall-Trigger, damit nicht alle Pläne gleichzeitig starten.
- Keine Läufe in den ersten 60 s nach dem Login (System kommt zur Ruhe).

Implementiert ist zunächst der isolierte Zeit-Scheduler als Package-Actor: injizierte monotone Uhr,
Wanduhr, Kalender und Jitter; ein abbrechbarer Timer; Konfigurationsersatz, Wake-/Uhrzeitabgleich und
höchstens eine Anforderung je fälligem Plan. Letzte Laufzeitpunkte werden vom aufrufenden Historienbesitzer
übergeben; ohne Historie beginnt ein neues Intervall am Startzeitpunkt. Wochenzeiten verwenden die
Kalenderregeln `nextTime`/`first` (Zeitlücke: nächste gültige Uhrzeit; doppelte Stunde: erste Instanz).
Intervall-Jitter ist auf ±60 Sekunden begrenzt und das resultierende Intervall mindestens eine Sekunde.
Planentfernung/Deaktivierung entfernt Timertermine; ein ausstehendes Nachholen bleibt bei Zeitzonenwechsel
erhalten. Timer-Stopp verhindert weitere Zustellungen, beendet aber keinen bereits angenommenen Lauf.
Der Empfänger muss jede Anforderung frisch über `ConfiguredJobRunner` zulassen und den geschützten
Engine-Pfad verwenden. `observeSystemEvents` verbindet den Scheduler über einen injizierten Monitor
mit Wake-, Uhrzeit- und Zeitzonenereignissen; andere Zustände werden als Hinweise weitergegeben.
Die Package-Laufzeitkomposition einschließlich automatischer Historienanker ist in §7.5 beschrieben; Agent-Anbindung erfolgt über `LocalBackupService`;
dieser Actor schaltet keine Quellfreigabe frei.

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
  mit Grund „MacKopia-Backup läuft“, garantiert freigegeben (defer / Deinit).
  `LocalSleepPreventer` liefert eine injizierbare, nebenläufig idempotent freigebbare Assertion.
  Die gemeinsame manuelle/automatische Engine erwirbt sie nach erfolgreicher Vorabprüfung und
  Optionsvalidierung, vor Serverstart. Sie bleibt bis zum Ende der Server-/Abbruchbereinigung aktiv;
  Fehler beim Erwerb verhindern den Start und werden als fehlgeschlagener Lauf protokolliert.
  Expliziter Ruhezustand und Display-Ruhezustand bleiben durch macOS steuerbar.

`LocalSystemEventMonitor` stellt eine abbrechbare kontinuierliche Beobachtung bereit: `NWPathMonitor`
als AsyncSequence mit Kosten-/Beschränkungszustand und verwendeten Interface-Typen; Energieänderungen
über IOKit-Run-Loop-Quelle und Stromsparmodus-Notification mit gemeinsamem frischen Power-Decoder;
Mount/Unmount über NSWorkspace und DiskArbitration einschließlich UUID-/Mountpfadänderungen.
Bereits beim Start gemountete Volumes werden als Ausgangszustand erfasst, nicht als neue Mount-Ereignisse.
Die Ereignisse enthalten UUIDs statt Volume-Namen oder Quellpfaden und geben keine Datenzugriffe frei.
Native Callbacks und Abbau laufen auf dem MainActor; schwache, nicht wiederverwendete Callback-Token
verhindern Zugriffe auf freigegebene Besitzer. Abbruch wartet auf beide Beobachter und entfernt Quellen,
Callbacks und Notification-Abonnements. Ein unerwartetes Stream-Ende oder Überlauf des auf 256 Ereignisse
begrenzten nativen Puffers liefert einen Fehler statt stillen Ereignisverlusts. Doppelte Power-/Netzwerk-
und Mount-Zustände werden unterdrückt. Der Netzwerkzustand ist kein Erreichbarkeitsnachweis für ein
Speicherziel. Die produktive Agent-Komposition erfolgt über `LocalBackupService` (§7.5).

`EventTriggerCoordinator` ordnet UUID-Ereignisse aktivierten Plänen mit `onVolumeMount` und passender
Quell- oder Zielvolume-UUID zu. Ein abbrechbarer monotoner Timer entprellt relevante Mount-Ereignisse pro
Plan für zehn Sekunden; mehrere passende Volumes ergeben eine Anforderung. Unmount entfernt dessen
ausstehende Ereignisgrundlage. Der Login-Schutz von 60 Sekunden gilt auch für Ereignis-Trigger.
Netzwerkzustandsänderungen prüfen ausschließlich konfigurierte Ziele: SFTP-Host/Port, WebDAV-/S3-URL
oder SMB-Remount-URL eines Dateisystem-Ziels. Ohne konfigurierten Host/Port entsteht keine Netzwerkanforderung.
Probes laufen sequenziell; gleiche Ziele samt Kostenrestriktionen teilen ein Ergebnis innerhalb des Ereignisses.
Unbekannte/gesperrte Kosten-/Beschränkungszustände und noch nicht prüfbare WLAN-Bedingungen verhindern Probes.
`TCPReachabilityChecker` verwendet die ab macOS 27 direkt verwendeten strukturierten Network-APIs: TCP-Aufbau mit
End-of-stream ohne Anwendungsbytes oder Zugangsdaten, maximal fünf Sekunden, mit anschließender
Transportbereinigung. Kosten-/Beschränkungsverbote gelten zusätzlich direkt am Verbindungsparameter.
Eine erfolgreiche Probe bestätigt weder TLS/Host-Key noch Anmeldung, Speicherplatz oder Quellfreigabe.
Vor Einreihung verlangt die neue `ConfiguredJobRunner`-Grenze exakt denselben aktuellen Plan und dasselbe
Speicherziel wie bei der Ereignisprüfung. Konfigurationswechsel, Netzwerkverlust und Stopp verwerfen
veraltete Antworten; Stopp wartet auf Timer-/Probe-/Zustellbereinigung. Ein bereits angenommener Queue-Eintrag
wird dadurch nicht entfernt und kein laufendes Backup abgebrochen. Jede spätere Ausführung bleibt an die
frische Vorabprüfung und den geschützten Engine-Pfad gebunden. Es gibt noch keine periodischen Ziel-Probes,
persistente Trigger-Zustände oder produktive Agent-/XPC-Komposition. Die automatische Engine-Drain-Schleife ist in §7.5 beschrieben.

### 7.5 Job-Queue & Zustandsmaschine

**Produktiver Dienstpfad (Phase 1/2):** Genau ein `LocalBackupService` im Hintergrunddienst besitzt
ConfigStore, HistoryStore, Keychain, Repository-Gate und die Lauf-/Setup-Steuerung. Die App importiert
weiterhin nur AgentProtocol/BackupDomain. Die lokale Einrichtung erzeugt oder verbindet ein bestehendes
Dateisystemziel; Anlegen verlangt einen leeren vorhandenen Ordner und mindestens zwölf Passwortzeichen.
Quelle und Ziel werden bereits bei der Ordnerauswahl an ihre Volume-UUID gebunden und im Dienst vor
Secrets, Bootstrap und Operation erneut geprüft. Dieselbe lokale Schutzgrenze deckt Setup und Backup ab.
Die einmal gewählte Snapshot-Identität wird bei weiteren Zielen wiederverwendet.

Anlegen/Verbinden und Konfigurationsänderungen sind gegen aktive Läufe serialisiert. Ein unbekannter
Schreibausgang entfernt weder Zielinhalte noch möglicherweise gespeicherte Credentials. Weitere Pläne
verwenden vorhandene Ziele; der Editor ändert Name, Aktivierung, Quellen, Aufbewahrung, Intervalle,
tägliche Uhrzeit, Mount-Trigger, Nachholen, Netzteilbedingung und optionales Auswerfen.
Neue Pläne bleiben bis zur bewussten Zeitplanwahl manuell. Bestehende komplexe/Wochentagstermine
bleiben über „Bestehende Termine beibehalten“ unverändert; „Täglich“ bedeutet alle sieben Tage.
Konfigurationsfehler sperren die Freigabe; nur die explizit bestätigte Recovery-Anfrage stellt eine gültige
Sicherung wieder her. `LocalBackupService` besitzt genau eine `AutomaticBackupRuntime`, die auch manuelle
Anfragen entgegennimmt. Nach Dienstneustart werden dauerhafte Queue-Absichten und Pausen gemäß §6.6
wiederhergestellt; Historienabgleich erfindet keine Erfolge. Shutdown joint Runtime, Mutation und Cleanup.

Dienstmutationen sperren Admission und Queue-Entnahme vor jedem suspendierenden Setup-/Schreibschritt;
aktive Backups führen zu `busy`, bevor die Mutation beginnt. Steueroperationen halten eigene UUID-Token
in der Queue, bis ihre Nacharbeit beendet ist. So kann die Abbruchbereinigung einer Prüfung keinen
Folgelauf vor Pause/Stopp starten; eine neue Steueroperation behält ihre eigene Sperre.
Explizite Verify-Anfragen laufen über denselben seriellen Drain wie Backups und automatische Nacharbeit.
Ausstehende explizite Prüfungen sind flüchtig; erst abgeschlossene Ergebnisse sind dauerhafte Evidenz.
Monitoringfehler sperren die Runtime; die explizite Aktion „Automatik neu starten“ joint den alten Besitzer
und startet eine frische Beobachtung unter Erhalt von Konfiguration und dauerhaften Pausen/Queue-Absichten.


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

Der zunächst eigenständige Queue-Baustein hält unveränderliche Planstände und arbeitet FIFO nach Eingang,
nicht nach dem übergebenen Zeitpunkt (dieser ist Ereigniszeit, kein Fälligkeitstimer). Zusammenfassen erhält
FIFO-Position, ersten Trigger und Zeitpunkt; der jüngste Planstand ersetzt den vorgemerkten Plan. Während
ein Plan aktiv ist, wird höchstens ein weiterer Auftrag dafür vorgemerkt. Andere Pläne können vorher
entnommen werden; derselbe Plan bleibt bis zum bestätigten Abschluss gesperrt. Abschluss benötigt die
konkrete Laufkennung, damit verspätete Rückmeldungen keinen neueren Lauf freigeben. Die Engine muss
Abschluss erst nach vollständigem Operations-Cleanup melden und Planfreigabe, aktuellen ConfigStore-Stand
sowie Repository-Sperre beim Start erneut prüfen. Die Queue startet selbst keine Prozesse; die dienstbesessene Runtime verbindet Scheduler, Retry, Historie und dauerhafte Wiederaufnahme.

`ConfiguredJobRunner` verbindet diese Queue explizit mit dem ConfigStore und der bestehenden geschützten
Operationsgrenze. Einlieferung und Entnahme lösen Plan/Speicherziel erneut aus der Konfiguration auf:
entfernte oder deaktivierte Pläne blockieren, automatische Trigger müssen weiterhin exakt eingerichtet sein;
manuelle Anfragen sind für jeden aktivierten Plan erlaubt. Beim Start ersetzt der aktuelle Plan den wartenden
Planstand. Direkt vor dem Operations-Callback wird nach allen suspendierenden Vorabprüfungen nochmals
Plan-/Speicherzielgleichheit geprüft. Die Laufkennung wird auf jedem Ausgang erst nach abgeschlossener
Operations-/Schutzbereinigung freigegeben. Dies ist keine Sperre gegen Konfigurationsänderungen während
einer bereits gestarteten Operation. Der generische Runner startet selbst keine Prozesse; der folgende
manuelle Engine-Pfad liefert den konkreten Operations-Callback und wird von der Package-Laufzeit wiederverwendet. Der manuelle Dienstpfad ist über `LocalBackupService` verdrahtet; die automatische Agent-Runtime folgt in Phase 2.

`ManualBackupEngine` verbindet diesen Runner explizit mit einer Dateisystem-Server-Sitzung: Secret frisch
auflösen, isolierte reguläre 0600-Konfiguration auf Zielpfad, gespeicherte Identität und deaktivierte Kopia-Actions
prüfen, Server starten, verbundenes Backend und Serveridentität bestätigen, alle Quell-Policies prüfen und
Quellen sequenziell sichern. Direkt vor jeder Quelle werden die Policies einschließlich Ausschlussresolvern
frisch geprüft. Eine erfolgreiche Upload-Antwort bestätigt nur die Annahme; Erfolg benötigt IDLE, eine neue
vollständige Snapshot-ID, deren eindeutig zugeordnetes gespeichertes Manifest und gültige Datei-/Byte-/Fehlerzähler. Kopia 0.23.1 fasst
in der normalen Snapshot-Liste identische Wurzeln zusammen; die Engine verwendet deshalb `all=true` für
Baseline und Abschlussnachweis. Auch unveränderte Folgeläufe erhalten so den richtigen Manifestbezug.

Fortschritt kommt quellgebunden höchstens einmal pro Sekunde mit optionalen Zählern; negative/fehlende
Zähler bleiben unbekannt. Byte-Durchsatz wird über ein 30-Sekunden-Fenster mit EWMA α=0,2 geglättet;
ETA erscheint erst nach 15 Sekunden gültiger Beobachtung. Es wird keine Upload-Mindestmenge vorausgesetzt.
Abbruch stoppt die aktuelle Quelle und überspringt die restlichen Quellen. Cancel-Anfrage plus IDLE-Bestätigung
haben zusammen ein kooperatives 30-Sekunden-Budget; bei fehlender Bestätigung wird dies in der Historie
vermerkt und die Server-Beendigung übernimmt die vorhandene stdin-/Signal-Eskalation mit Reaping.
Server-/Volume-Schutzbereinigung und abschließender Historienversuch enden vor Freigabe der Queue-Laufkennung.

`HistoryStore` verwendet GRDB 7.11.1, SQLite-Schema `history-v1`, private 0700-Verzeichnisse und 0600-Dateien.
Ein eindeutiger `running`-Eintrag wird vor der Startprüfung persistiert; genau ein terminaler Abschluss enthält
Plan-/Speicherziel-/Lauf-UUID, Trigger, Zeiten, Snapshot-/Root-IDs je abgeschlossener Quelle und deren Statistik
sowie ausschließlich feste Fehlercodes. Secrets, Rohdiagnostik und Quellpfade werden nicht gespeichert.
Schlägt der Starteintrag fehl, beginnt keine Operation; schlägt der Abschlusseintrag fehl, meldet der Aufrufer
einen Fehler statt Erfolg. Nicht abgeschlossene Einträge bleiben bis zum nächsten Runtime-Start nach
einem Prozessabsturz als `running` sichtbar. `JobHistoryRecovering` schließt sie vor Job-Freigabe in einer
SQLite-Transaktion als `cancelled` mit festem `processInterrupted`-Hinweis ab; Endzeit mindestens Startzeit,
keine Erfolgsbehauptung. Ungültige Payloads rollen die gesamte Abstimmung zurück und blockieren den Start.
Die produktive Komposition muss genau einen Runtime-Besitzer sicherstellen; Abstimmung darf nie parallel
zu einem weiterhin aktiven Engine-Besitzer aufgerufen werden. Ohne dauerhafte Queue-Absicht erzeugt
ein alter Historieneintrag keine neue Arbeit. History-Abschluss und Queue-Datei bilden keine gemeinsame
Transaktion: bereits terminale Einträge entfernen alte Absicht beim Start; ein Crash nach Snapshot-Erzeugung
vor Historienabschluss kann einen neuen inkrementellen Lauf bewirken. Logdatei-Verknüpfung und
Aktivitätsoberfläche folgen separat.

Der manuelle Durchstich unterstützt Dateisystem-Ziele und normale bzw. niedrige Prozesspriorität
(`QOS_CLASS_BACKGROUND` bereits bei `posix_spawn`). Noch nicht verdrahtete explizite Parallelitäts-/Bandbreiten-
und Auswerfen-Optionen blockieren vor dem Serverstart, statt still ignoriert zu werden. Netzwerkziele,
Plausibilitätsprüfung/Pinning und XPC-Komposition bleiben den weiteren Batches zugeordnet. Die produktive Quellfreigabe bleibt ohne FDA-/Kindprozessnachweis mit Ad-hoc-Vertriebsbuild gesperrt;
der Integrationstest autorisiert ausschließlich selbst erzeugte temporäre Quellen über einen Testadapter.

- **Retry-Strategie** bei transienten Fehlern (Netzwerk, Timeout, Ziel kurz weg): exponentiell 1 → 5 → 15 Min.,
  max. drei Wiederholungen zusätzlich zum ersten Lauf, danach `failed` + Mitteilung. Nicht-transiente Fehler (falsches Passwort, Repo nicht gefunden,
  Berechtigung) → sofort `failed`, kein Retry.
Der isolierte `BackupRetryCoordinator` verwendet eine injizierte monotone Uhr und hält je Plan eine
Wiederholungskette. Doppelte Fehlermeldungen desselben Laufs erzeugen keine zusätzlichen Timer;
nach drei Wiederholungen oder permanentem Fehler erfolgt genau eine terminale Rückmeldung pro Kette.
Jede Wiederholung liefert über `ConfiguredJobRunner` den geprüften Plan-/Speicherzielstand erneut ein;
geänderte Konfiguration verhindert die Aufnahme. Abbruch wird nie wiederholt. Reset/Stop bricht Timer
und laufende Aufnahme ab und wartet deren Ende ab. Die Laufzeitkomposition meldet erst nach
Historienabschluss, Prozessbereinigung und Queue-Freigabe Fehler und setzt Ketten bei Erfolg,
neuem regulärem Auftrag und Pause/Stopp zurück. Konfigurationswechsel erfolgen über den expliziten Live-Reload. Aktuell klassifiziert die
Engine nur `volumeDisappeared` automatisch als transient. Vertrauenswürdige Adapter können explizite
Netzwerk-/Timeout-Evidenz übergeben; pauschale Transport-/Kopia-Fehler bleiben permanent. Weitere typisierte Fehlerklassifizierung, produktive Agent-Anbindung und persistente Wiederaufnahme fehlen noch.

`AutomaticBackupRuntime` verbindet innerhalb des Package eine geladene Konfiguration, Zeit-Scheduler,
Systemmonitor, Ereignis-Trigger, Retry, Queue und den geschützten Dateisystem-Engine-Pfad. Sie erzeugt
Queue/Runner/Engine gemeinsam und besitzt genau einen seriellen Engine-Verbraucher. Ein separater
Queue-Beobachter reagiert auch während eines langen Laufs auf Pausenablauf; zusammengefasste Wakeups
tragen eine Pausenrevision, damit die Wiederfreigabe von Ereignis-Triggern nicht verloren geht.
`ManualBackupEngine.performNext(finished:)` meldet sein Ergebnis erst nach Historienversuch, Ressourcen-
Cleanup und Queue-Freigabe. Ein schneller fehlgeschlagener Retry wartet auf den Abschluss seiner noch
laufenden Einlieferung; ein zwischenzeitlicher Reset verwirft die alte Rückmeldung.

Pause/Stopp sperrt betroffene Einlieferungen, cancelt und joint suspendierende Admission-Worker und setzt
die Retry-Kette zurück. Planbezogene Ereignisversionen verwerfen alte Mount-/Probe-Evidenz, auch nach
schnellem Pause/Resume. Andere Pläne behalten ihre Debounce-Fristen und gemeinsam geprüfte TCP-Ergebnisse.
Während einer Steuermethode liefert eine weitere Steuermethode `repositoryBusy`, statt sich zu überholen.
Wake/Uhrzeit/Zeitzone gehen an den Scheduler, Wake/Uhrzeit zusätzlich an die Pausensteuerung. Ein fehlerhaftes
oder unerwartet beendetes Monitoring stoppt weitere Aufnahme, cancelt den aktiven Lauf und wartet dessen
Bereinigung ab; danach folgt ausschließlich ein fester `monitorUnavailable`-Code. Ebenso enthalten Lauf-
und Admission-Mitteilungen nur feste Codes mit Plan-UUIDs, keine Adapterdiagnostik oder Pfade.

Die Laufzeit hat explizites, idempotentes `shutdown` mit Join aller eigenen Worker und Pausentimer;
der Besitzer muss sie auch bei Fehlern so beenden. Shutdown ist terminal. `reloadConfiguration()` übernimmt
explizit den zuletzt vom ConfigStore akzeptierten Stand; Laden/Speichern bleibt Verantwortung des Besitzers.
Während des Abgleichs sind neue Admissions und Queue-Entnahme gesperrt; bestehende unveränderte Läufe
laufen weiter. Geänderte/entfernte Pläne oder geänderte Speicherziele werden über den normalen Abbruch-/
Historien-/Cleanup-Pfad beendet, ihre Folgeaufträge und Wiederaufnahmewünsche verworfen. Bestehende
Pausen bleiben erhalten; Pausen entfernter Pläne werden dauerhaft entfernt. Retry-Ketten und bisherige
Mount-/TCP-Evidenz werden verworfen; Ereignis-Trigger benötigen frische Systemereignisse. Der Scheduler
behält unveränderte Termine und berechnet neue Trigger mit Historienankern. Gleichzeitige Steuerbefehle
melden `repositoryBusy`. Lesefehler, Cancellation oder ein während der Vorbereitung veränderter Store
stoppen die Laufzeit mit festem `configurationUnavailable`-Code; ein paralleler Shutdown kann sie nicht
reaktivieren. Kein automatischer Dateiwächter und keine implizite Reparatur des Sicherheitsmodus.
Ohne explizites `start(lastRuns:)` lädt die Laufzeit
Anker über `JobHistoryScheduleReading`, sofern der Historienadapter dies unterstützt (`HistoryStore`
implementiert beide Protokolle). Pro aktiviertem Plan zählt der späteste Start eines erfolgreichen Laufs
(auch mit Warnungen) für dieselbe Plan-/Speicherziel-UUID, höchstens zur aktuellen Wanduhr.
Fehler, Abbruch, übersprungene und crashbedingt offene Läufe gelten nicht als Erfolg. Die Abfrage nutzt
die vollständige Historie statt einer begrenzten Recent-Seite. Ohne passenden Erfolg oder ohne lesenden
Historienadapter gilt der Startzeitpunkt; explizites `[:]` wählt dieses Verhalten auch bei vorhandener
Historie. Lesefehler stoppen den Start vor Scheduler/Monitoring. Nach suspendierendem Lesen werden
Cancellation und Laufzeitgeneration erneut geprüft, damit Shutdown keine verspätete Aktivierung zulässt.
Bestehende Login-/Nachholregeln gelten unverändert; dauerhafte Queue-Arbeit wird wie in §6.6 beschrieben restauriert. Die Konfiguration wird vor
jeder Queue-Aufnahme/Operation frisch geprüft. Unbestätigte Quellfreigabe bleibt `skipped`, ohne einen
Server zu öffnen. `LocalBackupService` aktiviert diesen Pfad auch für Agent/XPC/UI;
Persistenz noch nicht angenommener Trigger-Evidenz und Retry-Ketten sowie die Systemnachweise mit Ad-hoc-Vertriebsbuild bleiben offen.

- Jeder Lauf erzeugt einen `JobRun`-Eintrag in der Historie (Start, Ende, Ergebnis, Statistik, Snapshot-IDs, Fehlerliste,
  Verweis auf Kopia-Logdatei).
- **Plausibilitätsprüfung nach dem Snapshot** („Ransomware-/Unfall-Wächter“): Fällt die Dateianzahl oder Gesamtgröße
  gegenüber dem vorherigen Snapshot derselben Quelle um > 50 % (konfigurierbar), Lauf als `succeededWithWarnings` markieren,
  den neuen Snapshot **pinnen** und eine kritische Mitteilung zeigen. Optional: Retention bis zur Bestätigung aussetzen.

Implementierungsstand Batch 4b: Der gemeinsame manuelle/automatische Ausführungspfad vergleicht jede
Quelle mit dem zeitlich neuesten vollständigen Manifest aus der vor Upload gelesenen exakten
User-/Host-/Quellmenge. Ein fehlender Vorgänger benötigt keinen Vergleich; beschädigte vollständige
Vorgängerdaten blockieren vor Upload. `PlanOptions.plausibilityDropPercent` ist von 1 bis 100 konfigurierbar,
Standard und Decode-Fallback für ältere Konfigurationen sind 50. Verglichen werden Dateianzahl und
Gesamtgröße getrennt mit strikter `>`-Grenze und überlaufsicheren Ganzzahlprodukten; 100 löst keinen
Abfallalarm aus. Unvollständige Manifeste zählen nicht als Vorgänger.

Ein auffälliges neues Manifest erhält ausschließlich den zusätzlichen Pin `mackopia-plausibility` über
`POST /api/v1/snapshots/edit`. Kopia 0.23.1 ersetzt dabei die Manifest-ID; vorhandene Pins bleiben erhalten.
Eine exakte Quellabfrage bestätigt neue ID, Root, Start-/Endzeit, Statistik und Pin. Bei verlorener
Schreibantwort wird nur gelesen, kein Write wiederholt. Bestätigte neue IDs werden in der Historie
gespeichert; fehlende Bestätigung ergänzt `snapshotPinFailed`, ohne einen Schutz zu behaupten. Der Lauf
endet nach vollständigem Backup als `succeededWithWarnings`; Quelle und Lauf enthalten feste
`suspiciousSnapshot`-Codes. Der Health-Pfad zeigt diese bzw. fehlgeschlagenes Pinning kritisch mit
Aktivität als Folgeaktion. Bei nicht bestätigtem Pinning kann die letzte bekannte Manifest-ID bereits
ersetzt sein; der weiterhin gespeicherte Root bleibt die Inhaltsreferenz.

Pin-Versuch und Nachlesen bleiben unter der bestehenden Repo-/Volume-Reservierung und SleepAssertion;
Caller-Abbruch wartet auf diese begrenzten HTTP-Aufrufe, erhält das Quellergebnis und beendet weitere
Quellen. Der automatische Lauf liefert den kritischen Ereigniscode erst nach Cleanup und Queue-Freigabe,
auch bei anschließendem Abbruch/Fehler. Betriebssystem-Mitteilungen sind an die Agent-Komposition angeschlossen (§11.4);
ein automatisches Entpinnen oder Aussetzen der Aufbewahrung ist nicht implementiert.

### 7.6 Wartung & Prüfung

**Produktive Phase-2-Komposition:** Nach einem warnungsfreien erfolgreichen Lauf führt die alleinige
Runtime fällige 1-/10-Prozent-Verify-Stufen, den Test-Restore und die frische Wartungsprüfung seriell aus.
Alle verwenden denselben ConfigStore, HistoryStore, Keychain, Repo-Gate und Volume-/FDA-Schutz.
`MaintenanceHistory` speichert tatsächliche Full-Abschlüsse bzw. Fehler append-only mit Ziel-UUID,
Zeitpunkt und festem Ergebnis. Ein übersprungener oder abgebrochener Versuch erzeugt keinen Erfolg;
Owner und Termin werden nicht übernommen oder erzwungen. Test-Restore-Fehler bleiben in Health kritisch,
Wartungsfehler als Warnung sichtbar, auch nach Neustarts. Die folgenden Batch-Notizen beschreiben
Entstehung und Einzelverträge; ihre frühere offene Agent-Anbindung ist durch diesen Dienstpfad erfüllt.

Optionales Auswerfen erfolgt erst nach Abschluss der seriellen Nacharbeit, unter derselben Repo-Sperre
und erneuter Konfigurations-/Volume-UUID-Prüfung. Nur abnehmbare lokale Volumes sind zulässig.
DiskArbitration nutzt normale Unmount-/Eject-Optionen, respektiert Veto anderer Anwendungen und joint
native Rückmeldungen auch bei Cancellation. Kein Force-Unmount. Reale Hardware-Abnahme bleibt offen.

- **Wartung**: Kopia-Server führt Quick-/Full-Maintenance automatisch aus, wenn der Rechner Owner ist. Der `MaintenanceCoordinator`
  prüft nach jedem erfolgreichen Lauf `maintenance info --json` und startet fällige Full-Maintenance explizit
  (wichtig bei USB-Zielen, deren Server nur kurz läuft). Wartung niemals parallel zu einem Backup desselben Repos.
- **Verify** (Plan-Option, Standard: wöchentlich 1 % Stichprobe der Dateien, monatlich 10 %):
  `snapshot verify --verify-files-percent=<n>`. Ergebnis in Health und Historie.
- **Test-Restore** (monatlich, Standard an): zufällige Datei (< 50 MB) aus dem neuesten Snapshot in einen temporären Ordner
  wiederherstellen, SHA256 mit dem Original vergleichen (wenn unverändert laut mtime/size), Temp-Datei löschen.
  Ergebnis: „Wiederherstellung zuletzt erfolgreich getestet: <Datum>“ – das stärkste Vertrauenssignal für Nutzer.

Implementierungsstand Batch 4c: `HistoryStore.recordVerification` speichert abgeschlossene
Verify-/Test-Restore-Ergebnisse append-only mit Plan-/Ziel-UUID, Art, Start-/End-/Fälligkeitsdatum
und festem Erfolg-/Fehlercode. Keine Pfade, Rohdiagnosen oder Secrets. Datumsfehler und doppelte IDs
werden abgewiesen. Die SQLite-Migration erhält vorhandene Laufhistorie.
`HistoryStore.latestVerification` liest den letzten Nachweis getrennt nach Art und exakter
Plan-/Speicherziel-UUID bis zum angegebenen Zeitpunkt; damit bleibt auch Test-Restore-Evidenz
nach Neustarts lesbar, ohne sie als Verify-Erfolg zu behandeln.
`AutomaticBackupRuntime.health` liest den neuesten abgeschlossenen, nicht zukünftigen Verify-Nachweis
in derselben Transaktion wie die Laufhistorie. Ein Test-Restore ersetzt keinen Verify-Nachweis.
Gespeicherte Fehler bleiben kritisch bis zu einer zeitlich neueren erfolgreichen Prüfung; bei gleichem
Enddatum gewinnt der Fehler. Ein aktueller beobachteter Fehler bleibt ebenfalls kritisch. Gespeicherte
Fälligkeit kann durch flüchtige Erfolgsmeldungen nicht verlängert werden. Defekte Prüfhistorie macht
die Historie unverfügbar und damit Health kritisch. Automatische Prüfausführung, persistente laufende
Prüfabsichten, Test-Restore-Anzeige und Wartungskoordination bleiben offen.

Implementierungsstand Batch 4d: `SnapshotVerificationEngine.verify` führt eine explizit angeforderte
Prüfung des letzten erfolgreichen Backup-Laufs eines aktivierten Dateisystem-Plans aus. Sie verwendet
denselben `BackupOperationCoordinator` und dieselbe `RepositoryOperationGate` wie Backups, einschließlich
frischer Vorabprüfungen, UUID-Prüfung, Live-Laufwerksschutz und SleepAssertion während des Kindprozesses.
Der Besitzer muss dieselbe Gate-Instanz für alle Operationen verwenden. ConfigStore wird nach dem
Historienlesen und nach Ausführung erneut geprüft. Ohne vollständige Zuordnung zu allen aktuellen
Quell-UUIDs oder ohne gültige Manifest-IDs startet kein Verify. Aktuell erfordert dieser konservative
Pfad verfügbare Quellen samt Quellfreigabe; eine reine Offline-Speicherzielprüfung folgt separat.

Der CLI-Aufruf prüft ausschließlich diese Manifest-IDs in Batches bis 128, mit Prozentwert 1–100
(Standard 1), isolierter Config/Cache/Logs, Passwort ausschließlich in der Prozessumgebung,
expliziter niedriger Priorität und sechs Stunden Timeout pro Batch. Kopia 0.23.1 prüft ohne Zielangaben
das gesamte Speicherziel; leere, doppelte oder ungültige IDs werden daher vor Prozessstart abgewiesen.
Alle Batches müssen Exit 0, JSON-`errorCount` 0 und positive Objektarbeit melden. Ein gespeicherter
Erfolg entsteht erst nach Schutzbereinigung und erneuter Konfigurationsprüfung. Prozess-/Prüffehler
speichern einen festen Fehlercode vor Rückgabe des bereinigten Fehlers; Prozessabbruch erzeugt keinen
Prüfnachweis. Historienfehler bleiben Fehler. Fälligkeit ist standardmäßig sieben Tage, explizit
konfigurierbar bis 31 Tage. Automatische Prüfauslösung, Plan-Optionen für Verify, dauerhafte laufende
Prüfabsichten, Test-Restore-Ausführung und Wartungskoordination bleiben offen.
Der Erfolgszeitpunkt wird bereits nach tatsächlichem Kommandoabschluss unter der Reservierung erfasst;
verzögerte Schutzbereinigung oder Persistenz kann ihn nicht nachträglich hinter eine neuere Prüfung verschieben.

Implementierungsstand Batch 4e: `SnapshotVerificationEngine.testRestore` verwendet dieselbe Reservierung,
frischen Vorabprüfungen, UUID-/Live-Laufwerksschutz, SleepAssertion und Konfigurationsabgleiche wie Verify.
`FilesystemTestRestore` liest die gespeicherten Root-Objekte des letzten erfolgreichen vollständigen Laufs;
es wählt zufällig eine geeignete reguläre Datei unter 50 MB aus den aktuellen Quellen. Die Suche ist auf
256 Verzeichnisobjekte, 10.000 Einträge und 32 Ebenen je Quelle begrenzt, Prozessausgaben sind weiterhin
begrenzt. Leere Dateien sind zulässig, Links werden übersprungen. Dateinamen bleiben ausschließlich
lesende relative Komponenten; ungültige Namen oder Objekt-IDs werden abgewiesen.

Der CLI-Restore schreibt genau eine Objekt-ID unter einen festen lokalen Dateinamen in ein frisches
0700-Temp-Verzeichnis, mit sämtlichen Overwrite-Optionen deaktiviert, atomarem Schreiben und
übersprungenen Eigentümer-/Rechte-/Zeitstempelmetadaten (Kopia 0.23.1 erzeugt damit die Temp-Datei als 0600). SHA256 vergleicht Restore und Original
nur bei passender Snapshot-Größe und mtime (unter einer Mikrosekunde Rundungstoleranz). Original und
Restore werden über `openat` ohne Symlink-Verfolgung unterhalb ihrer kanonischen Wurzeln geöffnet.
Geräte-/Inode-/Größe-/mtime-/ctime-Abgleich sowie erneutes Hashen des Originals erkennen Änderungen
während der Prüfung. Fehlende geeignete Originale oder zwischenzeitliche Änderungen ergeben keinen
Prüfnachweis. Ein unverändertes Original mit abweichendem Restore ergibt einen festen Fehlernachweis.
Temporäre Daten werden vor Rückgabe auch bei Prozessfehler oder Abbruch entfernt; Cleanup-Fehler
können keinen Erfolg liefern. Erfolg/Fehler werden getrennt als `testRestore` gespeichert, standardmäßig
30 Tage gültig; sie ersetzen keinen Verify-Nachweis. Automatische Prüftermine, persistente laufende
Prüfabsichten, Anzeige und Agent-/XPC-Komposition bleiben offen.

Implementierungsstand Batch 4f: Der Besitzer kann `AutomaticTestRestore` in die gemeinsame Package-Laufzeit
injizieren; dessen Engine muss denselben Coordinator und dieselbe Repository-Sperre wie Backups verwenden.
Nach einem vollständig erfolgreichen, warnungsfreien Backup liest die Laufzeit den letzten abgeschlossenen
`testRestore`-Nachweis für Plan und Speicherziel. Ohne Nachweis oder ab dessen `dueAt` startet sie den
bestehenden geschützten Test-Restore. Der Standardabstand beträgt 30 Tage nach einem abgeschlossenen
Erfolg oder Fehler; Verify-Nachweise verschieben diesen Termin nicht. Eine unentscheidbare Stichprobe
bleibt ohne Nachweis und kann beim nächsten erfolgreichen Backup erneut versucht werden.

Die serielle Drain-Schleife wartet auf Prüfabschluss und Cleanup, bevor sie das nächste Backup entnimmt.
Pause (Plan/global), Stopp, Reload und Shutdown brechen die laufende automatische Prüfung ab und warten
auf deren Bereinigung. Prüffehler und Historienlese-/Schreibfehler melden ausschließlich den festen
Runtime-Code `testRestoreFailed` samt Plan-UUID; sie starten keine Backup-Retry-Kette. Backup-Historie
und Prüfhistorie bleiben getrennt. Ohne injizierten Prüfbesitzer startet keine Prüfung. Eigenständige
Prüftimer ohne vorheriges erfolgreiches Backup, automatische Verify-Stufen, Plan-Optionen und produktive
Agent-Komposition bleiben offen.

Implementierungsstand Batch 4g: `AutomaticSnapshotVerification` kann zusätzlich in die Package-Laufzeit
injiziert werden. Nach warnungsfreien erfolgreichen Backups liest sie den letzten `snapshotVerify`-Nachweis
für Plan und Speicherziel und führt ohne Nachweis oder ab `dueAt` die geschützte 1-Prozent-Prüfung aus
(Standardgültigkeit sieben Tage). Auch explizite Verify-Nachweise bestimmen diese Fälligkeit.
Verify läuft seriell vor dem Test-Restore unter demselben Coordinator und derselben Repo-Sperre.
Die Laufsteuerung bricht die gesamte Prüfnacharbeit ab und wartet auf Cleanup. Verify-Fehler melden nur
`verificationFailed` samt Plan-UUID, ohne Backup-Retry; ein unabhängiger Test-Restore bleibt möglich,
ohne den Verify-Fehler in Health zu verdecken. Ohne injizierten Besitzer keine automatische Prüfung.
Monatliche 10-Prozent-Stufe mit eigenem dauerhaftem Stufennachweis, Plan-Optionen, eigenständige
Prüftimer, Wartungskoordination und produktive Agent-Komposition bleiben offen.

Implementierungsstand Batch 4h: Verify-Ergebnisse enthalten zusätzlich den tatsächlich angeforderten
Dateianteil (`filesPercent`, 1–100); ältere Payloads bleiben ohne Anteil lesbar und zählen nicht als
Monatsnachweis. Test-Restore trägt keinen Anteil. Die art-/plan-/zielbezogene Historienabfrage kann
nach Mindestanteil filtern; auch ein neuerer kleiner Verify verdrängt so keinen größeren Nachweis.
Es werden keine historischen Prozentwerte erfunden und keine vorhandenen Zeilen umgeschrieben.

Die automatische Nacharbeit liest beide Stufen aus dauerhafter Historie. Ohne Nachweis von mindestens
10 Prozent oder ab 30 Tagen nach dessen Abschluss startet vorrangig eine 10-Prozent-Prüfung. Sie
ersetzt eine gleichzeitig fällige Wochenprüfung. Sonst startet die 1-Prozent-Prüfung spätestens sieben
Tage nach dem letzten Verify (bei früherem `dueAt` bereits dann). Auch explizite Prüfungen mit mindestens
10 Prozent zählen monatlich; Nachweise ohne bekannten Anteil zählen nur wöchentlich. Erfolge und Fehler
bestimmen den jeweiligen Wiederholungsabstand; Abbruch und abgewiesener Preflight verschieben keinen
Termin. Automatische Verify-Ergebnisse behalten sieben Tage Health-Gültigkeit, auch nach der größeren
Stichprobe; der unabhängige Monatstermin ergibt sich aus Abschlusszeit und gespeichertem Anteil.
Plan-Optionen, eigenständige Prüftimer, persistente laufende Prüfabsichten, Wartungskoordination und
produktive Agent-Komposition bleiben offen.

Implementierungsstand Batch 4i: `MaintenanceCoordinator.inspect` liest für einen aktivierten
Dateisystem-Plan die Wartungsauskunft unter derselben Repo-Reservierung, frischem Preflight,
UUID-/Live-Laufwerksschutz und SleepAssertion wie Backup und Verify. Die Konfiguration wird
vor und nach dem Lesen abgeglichen. `FilesystemMaintenanceInspection` validiert die isolierte
Verbindung und löst das Passwort frisch aus dem Schlüsselbund; `KopiaMaintenanceReader` führt
nur `maintenance info --json` mit begrenzter Laufzeit und Ausgabe aus. Die Auswertung vergleicht
den Owner exakt mit der gespeicherten Override-Identität und unterscheidet fehlenden/fremden Owner,
deaktivierte Full-Wartung, fälligen und zukünftigen Termin. Kopia 0.23.1 liefert Intervalle als
Nanosekunden und bei noch fehlendem Termin Go-Zero-Time (Jahr 1); dieser Termin ist fällig.
Defekte Pflichtfelder werden abgewiesen, Rohdiagnosen aus der Wartungshistorie nicht übernommen.
Das Ergebnis ist nur eine Beobachtung und kein später wiederverwendbares Ausführungsrecht.
Implementierungsstand Batch 4j: `MaintenanceCoordinator.runDueFull` liest Owner und Termin frisch
innerhalb derselben Reservierung und startet ausschließlich bei eigenem Owner, aktivierter Full-Wartung
und erreichtem Termin. Konfigurationsabgleich vor dem Lesen, vor dem Start und nach Prozessende;
SleepAssertion und Live-Laufwerksschutz bleiben bis zum Cleanup aktiv. Der injizierte
`KopiaMaintenanceRunner` führt nur `maintenance run --full` aus, ohne Force-/Safety-Overrides,
mit isolierter Umgebung, begrenzter Ausgabe und sechs Stunden Timeout. Fehlender Prüfzugang,
fremder/fehlender Owner, deaktivierte oder noch nicht fällige Wartung starten keinen Prozess.
Ein erfolgreicher CLI-Abschluss ist noch keine dauerhafte Wartungsevidenz.
Owner-Übernahme, automatische Runtime-Anbindung und Wartungshistorie folgen separat.

### 7.7 Health-Bewertung

Pro Plan eine Ampel mit Begründung (in Übersicht, Menüleiste, Mitteilungen):
- 🟢 OK: letzter erfolgreicher Lauf < `warnAfter`, letzte Prüfung ok.
- 🟡 Warnung: Lauf älter als `warnAfter`, Warnungen im letzten Lauf, Ziel > 90 % voll, Verify überfällig.
- 🔴 Kritisch: älter als `criticalAfter`, Passwort fehlt/falsch, Verify fehlgeschlagen, FDA fehlt, Agent nicht erlaubt.
Jede Meldung hat eine **konkrete Aktion** („Laufwerk anschließen“, „Passwort eingeben“, „Festplattenvollzugriff öffnen“).

Implementierungsstand Batch 4a: `AutomaticBackupRuntime.health(planID:observations:)` liefert eine rein
lesende Package-Abfrage mit festen `HealthAssessment`-Gründen, Schweregrad und Folgeaktionen. Die
SQLite-Historie liest in einer konsistenten Transaktion den letzten abgeschlossenen und den letzten
erfolgreichen Lauf für dieselbe Plan-/Speicherziel-UUID über den gesamten Bestand; laufende und zukünftige
Ergebnisse gelten nicht als Erfolg. Health-Alter bezieht sich auf das Ende des erfolgreichen Laufs,
Warn-/Kritisch-Schwellen gelten einschließlich der Grenze. Neuere Fehler verdecken weder den letzten
Erfolg noch dessen Warnungen. Fehlende Erfolge warnen; fehlende/defekte Historie ist kritisch. Eine
Konfigurationsänderung während der Abfrage verwirft das Ergebnis.

Aktuelle Passwort-/FDA-/Dienst-Beobachtungen, Kapazität und Prüfergebnis werden typisiert vom Besitzer
übergeben; die Abfrage löst keine Prozess-, Schlüsselbund- oder Dateizugriffsprobe aus. Ohne Prüfnachweis
bleibt eine Warnung statt eines grünen Vertrauenssignals. Erfolgreiche Prüfungen enthalten Prüfzeit und
Fälligkeit; zukünftige/ungültige Nachweise warnen, fehlgeschlagene Prüfungen sind kritisch. Die festen
Codes enthalten keine Pfade, Secrets oder technischen Rohdiagnosen. Lokalisierte Darstellung,
Prüf-/Wartungsnachweise und konkrete Folgeaktionen sind über den Dienst an Fenster und Menüleiste
angeschlossen. Frische Preflight-Warnungen zur Zielkapazität werden als Beobachtung übernommen;
die Health-Abfrage selbst startet weiterhin keine Prozesse oder Secret-/Zugriffsproben.

---

## 8. Sicherheit

1. **Secrets** (Repo-Passwort, S3-Keys, SFTP-Passwort/Key-Passphrase) ausschließlich im **Keychain**,
   verwaltet durch den Hintergrunddienst; die UI übergibt Secrets per authentifiziertem XPC.
   `AgentKeychainStore` verwendet die modernen SecItem-Operationen im lokalen Login-Keychain ohne
   Team-ID, Data-Protection-Flag oder Access Group. Die Standard-ACL gehört der anlegenden signierten
   Anwendung; niemals eine All-App-ACL setzen. `LAContext.interactionNotAllowed` verhindert Dialoge im
   Hintergrund; fehlender/gesperrter Zugriff blockiert ohne Ersatzdatei. Der alte explizite Team-Adapter
   bleibt ausschließlich für seine bestehenden Vertragsprüfungen erhalten. Update-Stabilität der
   Ad-hoc-Identität ist ein gesonderter Release-Nachweis, keine Zusage dieses Adapters.
   `kSecAttrSynchronizable = false` (Standard; Synchronisierung nur nach bewusster Produktentscheidung).
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
   Angeboten nach dem Anlegen, jederzeit im Restore-Bereich erneut abrufbar. Der integrierte Phase-3-Pfad
   verwendet den nativen Druckdialog einschließlich „Als PDF sichern“, ohne Passwort; es gibt keine Secret-Rückgabe.
   Drucklayout/PDF-Ausgabe bleiben Teil der manuellen UI-Abnahme.
5. **XPC-Härtung**: Swift-XPC-API (`XPCListener`/`XPCSession`) mit Peer-Requirement aus exakter
   Signing-ID und CodeDirectory-Hash des jeweiligen Partners im lokal signierten App-Bundle.
   Eigene laufende Signatur, Bundle-Layout und äußeres Bundle-Siegel werden vor Verbindungsaufbau geprüft.
   Keine Team-ID erforderlich; kein ungeprüfter Ersatztransport. Das installierte Bundle ist der
   Vertrauensanker, keine durch Apple bestätigte Herausgeberidentität. Alle Requests validieren
   (Pfade existieren, IDs bekannt, Größen begrenzt). Protokoll versioniert (`protocolVersion` im Handshake; Mismatch → UI fordert Neustart des Agents).
6. **Lokale Kopia-API**: nur `127.0.0.1`, TLS mit Pinning, Zufallspasswörter pro Start, stirbt mit dem Agent.
7. **Hardened Runtime** ohne Ausnahmen (keine `disable-library-validation`, kein JIT). Keine zusätzlichen
   Entitlements für Ad-hoc-Vertrieb; keine Team-basierte Keychain-Gruppe, kein Sandbox-Entitlement.
8. **Festplattenvollzugriff**: Prüfung durch Leseversuch einer TCC-geschützten Datei (z. B. `~/Library/Safari/Bookmarks.plist`,
   Fallback `~/Library/Mail`) **aus dem Agent-Prozess**. Fehlt FDA, führt die UI zu
   `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` und zeigt eine Schritt-für-Schritt-Grafik.
   **Systemnachweis (integrierter Dienst / Release)**: verifizieren, welchem Prozess TCC den Zugriff des Kindprozesses `kopia` zuordnet (verantwortlicher Prozess =
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

`LocalSourceAccessChecker` ist ein explizit zu injizierender Quellzugriffsadapter; der Standard bleibt
`UnknownPreflightObservations`. Er verlangt zunächst einen frischen geschützten Leseversuch über
`FullDiskAccessProbing` und liest danach jedes übergebene Quellverzeichnis mit `opendir`/`readdir` an.
Der experimentelle Adapter verlangt diesen Nachweis konservativ für alle Quellen; eine reine Pfadpräfixliste
könnte geschützte Nachfahren oder Symlinkziele übersehen. Dies ist noch keine produktive FDA-Onboarding-Regel.
`LocalFullDiskAccessProbe` liest höchstens ein Byte aus `~/Library/Safari/Bookmarks.plist`, nur bei fehlender
Datei folgt ein Leseversuch von `~/Library/Mail`. Fehlende Testdaten oder andere unklare Fehler bleiben
`unknown`, verweigerte Rechte ergeben `denied`. Kein Metadaten-/`access`-Check wird als Leseerfolg gewertet.
Dateideskriptoren werden auf jedem Ausgang geschlossen; finale Dateisymlinks und Spezialdateien werden
abgewiesen, FIFO-Öffnung ist nicht blockierend. Inhalte, Eintragsnamen und rohe Fehler werden nicht ausgegeben.
Die Leseabfragen laufen auf einem separaten Actor mit Abbruchprüfung vor/nach den Systemaufrufen; blockierende
Dateisystemaufrufe selbst sind damit weder unterbrechbar noch zeitlich begrenzt. Kein rekursiver Scan und
kein Nachweis der Lesbarkeit jedes Nachfahren. Quellenidentität und Live-Schutz bleiben separat erforderlich.
Der produktive Phase-1-Pfad komponiert den Adapter mit `AgentFullDiskAccessProbe`: zusätzlich zum
Agent-Leseversuch muss das exakt gebündelte Kopia dieselbe nichtleere reguläre Safari-Bookmarks-Datei
selbst lesen. Kopia 0.23.1 `benchmark compression --algorithms=none --repeat=1` liest den Inhalt vor
Algorithmusauswahl, arbeitet ohne Repository und gibt keine Inhalte aus. Datei-/Content-Logging ist für
diese Probe aus; Ausgaben werden begrenzt erfasst und verworfen. Vorprüfung: kein Symlink, höchstens
1 MiB; Kopias eigener harter Lesedeckel bei gleichzeitigem Dateiwachstum beträgt 128 MiB, Timeout 10 s.
Fehlende/übergroße Testdatei, Kindprozessfehler oder unklarer Zugriff bleiben `unknown`; der Mail-Fallback
allein erteilt keine Kindprozessfreigabe. Es gibt keinen gespeicherten FDA-Freischalter. Tests verwenden
nur synthetische temporäre Daten. Die konkrete Systemeinstellungen-/Update-Zuordnung bleibt separat
am installierten Dienst manuell nachzuweisen; automatische Leseevidenz wird vor jedem Lauf frisch erhoben.

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

`MacOSExclusionPatterns` Version 1 erzeugt diese verpflichtenden Muster rein lexikalisch mit explizit
übergebenem Home-Verzeichnis des gesicherten Benutzers. Home-bezogene Library-Regeln werden nach
Pfadkomponenten auf die Quelle projiziert und mit `/` an deren Wurzel verankert; fremde Quellen erhalten
sie nicht. Liegt die Quelle selbst in einem ausgeschlossenen Home-Unterbaum, liefert der Baustein explizit
`**` (alle Einträge ausgeschlossen). Glob-Zeichen in echten Pfadkomponenten werden maskiert; nur das
fest definierte Containers-Segment bleibt ein Wildcard. Universelle Namensregeln bleiben rekursiv.
Optionale MobileSync-/Entwickler-Schalter sind noch nicht modelliert und werden nicht aktiviert.
Keine Dateisystemzugriffe, Symlink-/Volume-Prüfung, Time-Machine-Abfrage, Cache oder automatische
Policy-Übertragung; der Aufrufer muss Quellidentität und Aktualität weiterhin sicherstellen.

- `honorTimeMachineExclusions` → beim Policy-Abgleich die Quelle flach bis Tiefe 3 nach `URLResourceKey.isExcludedFromBackupKey`
  scannen (plus `tmutil`-Sticky-Exclusions via `com_apple_backup_excludeItem`-xattr) und als Ignore-Regeln übernehmen.
  Expliziter Resolver scannt Wurzel und drei Nachkommenebenen mit maximal 10.000 Einträgen auf einem separaten
  Dateisystem-Actor; keine Symlink-Traversierung oder fremden Volumes. Fehlende Metadaten, Lesefehler und
  Budgetüberschreitung verwerfen das gesamte Ergebnis. Quellrelative Literalmuster sind maskiert und verankert,
  ausgeschlossene Wurzel liefert `**`. Ergebnis ist an die vollständige Quelle und einen monotonen Zeitpunkt
  gebunden (höchstens 60 s wiederverwendbar); ein interner Cache und produktive Policy-Anbindung fehlen noch.
  Das 10-s-Limit gilt kooperativ vor/nach I/O; blockierende Kernel-Dateisystemaufrufe sind nicht hart unterbrechbar.
  Pfadprüfungen sind Beobachtungen, keine rennfreie Dateideskriptor-Traversierung. Die Auflösung erfasst nur
  dasselbe Volume und verweigert `oneFileSystem=false`; bei späterer volumeübergreifender Sicherung ist
  zusätzliche Ausschlussauflösung nötig. Sticky-xattr: `com.apple.metadata:com_apple_backup_excludeItem`.
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
  Leertaste = Quick Look (Datei über denselben abgesicherten Manifest-/Namensrestore in
  `~/Library/Caches/MacKopia/QuickLook/` laden, beim Schließen löschen).
  „Wiederherstellen…“ → Sheet: Ziel-Elternordner (Standard: `~/Downloads/`), Auswahl/Metadatenhinweis und Start.
  Phase 3 erstellt darunter atomar einen privaten Ordner `MacKopia-<UUID>/` (0700), darin die ausgewählte Datei,
  den Ordner oder `Restore/` für den gesamten Snapshot. Alle Kopia-Overwrite-Schalter bleiben aus;
  übersprungene Dateien oder ignorierte Fehler ergeben keinen Erfolg. Teilresultate bleiben bei Abbruch erhalten.
  Überschreiben und „An ursprünglichem Ort wiederherstellen“ werden nicht angeboten; solche erweiterten
  Varianten benötigen vor Freigabe eine explizite Bestätigung und nachgewiesenen Konflikt-/Symlinkschutz.
  Berechtigungen/Zeitstempel werden übernommen; die UI nennt die bekannten xattr-/ACL-/Finder-Metadatenlimits.
  Suche über Dateinamen im ausgewählten Snapshot (lazy, mit Abbruch): höchstens 256 Verzeichnisse,
  10.000 Einträge, 500 Treffer und Tiefe 64, mit sichtbarem Hinweis bei Begrenzung.
  Browserseiten enthalten höchstens 2.000 Einträge; der Katalog höchstens 128 Quellen/1.000 Snapshots/8 MiB.
  Größere Seiten/Kataloge werden ausdrücklich abgewiesen statt als vollständig leer oder vollständig geladen dargestellt.
  Der Snapshot-Selektor behält die vollständige fremde Benutzer-/Rechneridentität; lokale Originalquellen sind nicht nötig.
  Quick Look stellt ausschließlich Dateien bis 50 MB unter einem privaten Cache-Sitzungsordner wieder her und
  löscht die eigene Sitzung beim Schließen bzw. Dienst-Shutdown. Ein harter Prozessabbruch kann Cache-Reste hinterlassen.
  Beschreibung/Nutzer-Pin sind bearbeitbar; Sicherheits-Pins werden nie entfernt, geänderte Manifest-IDs frisch geladen.
- **Aktivität**: `Table` aller `JobRun`s (Plan, Trigger, Start, Dauer, Ergebnis, Datenmenge), Detail mit Fehlerliste
  (Datei + Grund) und „Kopia-Log anzeigen“.

### 11.3 Menüleiste (Agent)
Icon-Zustände: idle (Häkchen), läuft (animiert), pausiert, Warnung, Fehler. Inhalt (`.menuBarExtraStyle(.window)`):
Status je Plan (Ampel, „vor 12 Min.“), laufender Fortschritt, Buttons „Jetzt sichern“ (alle/Plan), „Pausieren ▸ 1 Std. /
bis morgen / unbegrenzt“, „MacKopia öffnen“, „Wiederherstellen…“. Es gibt bewusst **kein** einfaches „Beenden“:
„Hintergrunddienst beenden“ steht unter „Erweitert“, deaktiviert alle automatischen Backups und verlangt eine Bestätigung.

### 11.4 Mitteilungen (`UserNotifications`, aus dem Agent)

**Verdrahteter Stand:** explizite Einstellung `notificationsEnabled` in der Agent-Konfiguration,
Standard aus (auch beim Decoding älterer Schema-1-Dateien). Nur die bewusste Aktivierung fordert die
Systemberechtigung an; Wiederanlauf und Previews erzeugen keinen Berechtigungsdialog.
Probleme werden pro Plan höchstens einmal je 24 Stunden gemeldet, der erste erfolgreiche Lauf einmal;
reguläre Erfolge und erwartetes Warten auf Energie-/Netzwerkbedingungen bleiben still.
Die reine `BackupNotificationPolicy` ist getestet; das nicht geheime UUID-/Datumsledger liegt im Agent
in UserDefaults. Mitteilungsdaten enthalten feste Texte und eine Plan-UUID; „Erneut versuchen“ und
„Details anzeigen“ führen zurück in den Dienst bzw. die App. Nativer Zustellnachweis bleibt offen.
Weitere Mitteilungsvarianten und die unten genannten erweiterten Aktionen gehören zur UI-Abnahme in Phase 5.
- Nur relevante: Fehler, Warnungen, „Laufwerk erkannt – Backup gestartet“ (abschaltbar), erstes erfolgreiches Backup,
  Health kritisch (max. 1×/Tag), Plausibilitätswarnung. Erfolgsmeldungen bei jedem Lauf standardmäßig **aus**.
- Aktionen in Mitteilungen: „Erneut versuchen“, „Details“, „Backup stoppen & auswerfen“.

### 11.5 Lokalisierung
`Localizable.xcstrings` (Deutsch = Entwicklungssprache, Englisch vollständig), Pluralregeln über den Katalog,
Byte-/Datumsformatierung ausschließlich mit `ByteCountFormatStyle`, `Date.FormatStyle`, `Duration.UnitsFormatStyle`,
`.relative(presentation:)`. Keine zusammengesetzten Strings, keine hartcodierten Formate.

---

## 12. App ↔ Agent-Protokoll

**Verdrahteter Phase-1/2/3/S3-Vertrag (Version 5):** `AgentServiceClient/Server` transportieren begrenzte
JSON-Daten in einem Codable-XPC-Umschlag. Vor der Domain-Dekodierung gelten 1 MiB für Requests und
16 MiB für Antworten. Version/UUID korrelieren jede Antwort; Secrets sind ausschließlich in Setup- und Credential-Aktualisierungsrequests zulässig.
Jede authentifizierte Sitzung nimmt genau einen Request an und sendet die asynchrone Antwort über
dieselbe Sitzung. Die öffentlichen Produktionskonstruktoren erzwingen weiterhin Code-Hash-Pinning;
der anonyme Testendpoint existiert ausschließlich im Testtarget.

Implementiert: Zustand, lokales und S3-Erzeugen/Verbinden, geprüfter S3-Credential-Ersatz, neuer Plan am vorhandenen Ziel, validiertes Plan-Update,
explizite Konfigurations-Recovery, manueller Start/Stopp, Plan-/globale Pause mit absoluter Frist,
Fortsetzen, explizites Verify, Mitteilungseinstellung und Automatik-Neustart; außerdem Snapshot-Katalog/Browser,
begrenzte Suche, Beschreibung/Nutzer-Pin, Restore-Admission/Abbruch und Quick-Look-Cache-Lifecycle.
Snapshot-ID und validierte Namenskomponenten ersetzen rohe Objekt-IDs vom Client. Der Dienst löst jede Auswahl
über frische Manifeste/Verzeichnisabstammung auf; Kopia erhält exakte gespeicherte Unicode-Namensbytes.
Restore reserviert dieselbe Repo-Sperre und Automatik-Steuersperre bis zum vollständigen Server-Cleanup,
überwacht Ziel und Ausgabevolume und benötigt keinen Zugriff auf die Originalquellen. Er bleibt auch bei
angehaltener Automatik möglich, sofern kein konkurrierender Zugriff die gemeinsame Sperre besitzt.
Zustände enthalten
Konfiguration, maximal 50 jüngste Läufe, aktive Plan-ID, Fortschritt und feste Fehlercodes sowie
planbezogene Termine/Pausen/Health und artgetrennte Verify-/Test-Restore-/Wartungsnachweise sowie eine
begrenzte Restore-Projektion (Katalog/Seite/Suchtreffer oder laufende Operation mit UUID, Bytes, Dateien und Ergebnis).
Ungültige Daten und nicht endliche Fristen werden mit festem Fehler abgewiesen; ältere Versionen werden nicht still weiterverwendet. `state(after:)` wartet ereignisgesteuert
auf eine neue Revision (maximal 25 s / acht Beobachter); so transportiert eine neue Momentaufnahme
State-/Progress-/Run-Ereignisse ohne Idle-Polling. Clientfrist 90 s, Cancellation trennt die Sitzung und
beendet den zugehörigen Request; ein bereits angenommener Lauf gehört dem Dienst bis zum expliziten Stopp.
`AgentConnection` lädt nach Reconnect eine vollständige Momentaufnahme; nur fehlgeschlagene Verbindungen
werden mit fünf Sekunden Abstand erneut versucht. Setup-/Plan-Stores und sichere Previews gehören der UI.
Die unten genannten weiteren Requests und dedizierten Stores sind Zielumfang der Folgephasen.


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
  `AgentPingServer` akzeptiert nur die exakte Signing-ID und den CodeDirectory-Hash der App
  aus dem geprüften Eltern-Bundle. Der Client pinnt entsprechend den eingebetteten Agent.
  Beide prüfen ihre laufende Signatur gegen das eigene Bundle; lokale Ad-hoc-Signaturen genügen.
  Ungültige/unsignierte Bundles erhalten keinen ungesicherten Ersatztransport.
  `AgentServiceRegistration` kapselt explizite Registrierung, Status und den Sprung zu Anmeldeobjekt-Einstellungen.
  Der Ping-Vertrag bleibt ein historischer Testbaustein; produktiv startet der Agent den folgenden versionierten Dienstlistener.
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
CI auf `xcode-27` (macOS 27/arm64) mit expliziter stabiler Xcode-Auswahl, aktuell 27.1:
`fetch-kopia` (gecacht) → Python-Skriptprüfungen → Format → eine Package-Suite inklusive Integration
→ ein Xcode-`build test`. Läuft auf prüfbereiten PRs, Release-Tags und manuell; veraltete Läufe abbrechen.
Lange historische Backend-/Server-Spikes nur manuell bei betroffenem Vertrag oder bei Release-Tags, nicht
redundant bei jedem kleinen Push. Die [Runner-Bezeichnung ist bei GitHub dokumentiert](https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/).

bei Tag: Archive, lokal ad-hoc signieren, Signaturen prüfen, DMG, Appcast. Keine Apple-Zugangsdaten erforderlich. `swift format lint --strict` (Apples swift-format aus der Toolchain,
Konfiguration `.swift-format` im Repo) als Pflicht-Check.
Die Bundle-/Signaturtests laufen als eigenständiges Testbundle außerhalb der Produkt-App.
Eine Ad-hoc-XCTest-Injektion in die geschützte App scheitert an Library Validation; deshalb
werden weder Runtime noch Library Validation für Tests gelockert. App, Agent und Kopia
werden am gebauten Artefakt auf gültige Signatur und gesetztes Runtime-Flag geprüft.

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

## 14. Umsetzungsplan – integrierte Produktphasen

**Verbindliche Neufassung vom 2026-10-25.** Dieser Plan ersetzt die alte Phase-0-/Batch-Abfolge.
Vorhandene Kopia-/Engine-/Persistenz-Bausteine werden weiterverwendet, nicht neu geschrieben.
Der aktuelle Stand und der nächste konkrete Auftrag stehen in [STATUS.md](STATUS.md);
der kompakte Implementierungsatlas in [IMPLEMENTIERUNG.md](IMPLEMENTIERUNG.md).
Der [alte Plan](history/PLAN-bis-2026-10-25.md) dient nur zum Verständnis historischer Nachweise.

### Arbeitsweise

- Ein Auftrag liefert einen größeren integrierten Funktionsblock samt Fehler-/Abbruchpfaden,
  Tests und Übergabe. Nicht nach jedem Adapter, Dateityp oder kleinen Testlauf anhalten.
- Ein `continue coding` setzt den nächsten Auftrag aus STATUS.md bis zu seinem nutzbaren Ergebnis fort.
  Unteraufgaben werden ohne erneute Nutzerfreigabe verbunden; Kontextkompaktierung ist kein Abschluss.
- Die Phasen sind Reihenfolge und Zielbilder, keine globale Sperrkette. Fehlt ein Systemnachweis,
  wird nur die betroffene reale Funktion gesperrt; unabhängige UI-/Engine-Arbeit geht weiter.
  „Implementiert“, „integriert“, „automatisiert geprüft“ und „manuell geprüft“ bleiben unterscheidbar.
- Alle Sicherheitsinvarianten aus AGENTS.md bleiben bindend. Ungeprüfte Datenzugriffe, Authentifizierung
  oder destruktive Funktionen werden nicht bloß zum Abschluss einer Phase freigegeben.
- Tests während der Umsetzung entstehen mit der Logik; Ausführung erfolgt gebündelt an sinnvollen
  Block-/Phasengrenzen. Gezielte Reproduktion/Diagnose bei konkretem Fehler bleibt erlaubt (vom Nutzer ausdrücklich bestätigt).
  Eine vollständige Prüfrunde auf dem finalen Codezustand; keine Wiederholung nach reinen Dokuänderungen.
- Ausschließlich die gemeinsame Arbeits-/Prüf-/Kontextregel aus AGENTS.md §5 gilt für alle Agents.
  Kleine Commits bleiben möglich, ohne nach jedem Commit den Nutzer erneut um Fortsetzung zu bitten.
- Neue Plattform-APIs werden anhand des installierten macOS-27-SDKs ausgewählt. Native Effizienz,
  Klarheit und Barrierefreiheit sind das Ziel; zusätzliche Frameworks ohne konkreten Bedarf sind es nicht.

### Phase 1 – Nutzbarer lokaler Backup-Workflow (implementiert)

**Ergebnis:** Die native App kann ein lokales Speicherziel und einen Plan anlegen/verbinden,
ein Backup auslösen/stoppen und echten Status samt Ergebnis anzeigen; der Dienst besitzt die Engine.

Zusammenhängende Umsetzung:
- Keychain-Zugriff ohne Team-ID, ausschließlich im Hintergrunddienst; keine Secret-Ersatzdateien.
- Ein produktiver Runtime-Besitzer im Agent; gemeinsame Repo-Sperren, Konfigurations-/Historienzugriff,
  Shutdown und vollständiger Cleanup auf Basis der vorhandenen Engine.
- Validierte versionierte XPC-Requests/Events für Konfiguration, Einrichtung, Laufsteuerung und Status;
  Code-Hash-Pinning, Größenlimits, Reconnect und klarer Berechtigungs-/Dienststatus.
- App-weite AgentConnection, Navigation, lokale Einrichtung und Planbearbeitung, Übersicht,
  Fortschritt, Ergebnis, leere/fehlende-Berechtigungs-/offline- und Fehlerzustände; DE/EN und Previews.
- SMAppService/FDA aktiv am echten integrierten Pfad prüfen, soweit lokal ohne neue Zustimmung möglich.
  Erforderliche Nutzeraktionen exakt dokumentieren; mit sicheren Mocks die restliche UI weiterbauen.

**Prüfblock am Ende:** Package-Suite inkl. echtem temporärem Backup/Abbruch/Restore-Nachweis,
Xcode build/test, Format-Lint; ein vertikaler App→XPC→Agent→Engine-Durchstich soweit freigegeben.
Fehlende Live-Freigaben separat erfassen. Nicht die Engine erst um jede spätere Komfortfunktion erweitern.
**Einstiegsstellen:** §5–§6, §7.1/§7.3–§7.5, §8–§9, §11–§12; IMPLEMENTIERUNG.md.

### Phase 2 – Zuverlässiger täglicher Betrieb

**Ergebnis:** Bestehende Pläne sichern automatisch, zeigen nachvollziehbare Gesundheit und erlauben
Steuerung aus Fenster und Menüleiste; Termine und Zustände überleben Neustarts.

Runtime vollständig mit Scheduler, Volume-/Netzwerk-/Energie-/Wake-Ereignissen und persistenten
Pausen/Retry/Recovery verbinden. Health, Plausibilitäts-Pinning, wöchentliche/monatliche Verify-Stufen,
Test-Restore und fällige Wartung samt dauerhafter Evidenz und Mitteilungen integrieren.
Aktivität, zielbezogene Fehler/Folgeaktionen, relevante Einstellungen und sichere Auswerfen-Optionen
als zusammenhängende Nutzerwege fertigstellen. Ereignisgetrieben, kein unnötiges Polling;
Fortschritt begrenzen, Cancellation/Cleanup und SleepAssertions konsistent halten.

**Prüfblock:** virtuelle Uhr/Ereignisse/Neustart, gemeinsame Repo-Serialisierung, Fehler-/Pause-/Abbruchpfade,
ein temporärer Gesamtdurchstich; volle Package-Suite und betroffene Xcode-Prüfung einmal am Blockende.
**Einstiegsstellen:** §6.6, §7.3–§7.7, §9, §11.3–§11.4, §12.

### Phase 3 – Vollständige Wiederherstellung und Recovery (integriert, Live-Abnahme offen)

**Ergebnis:** Ein Backup lässt sich in der App finden, prüfen und ohne stilles Überschreiben wiederherstellen.

Snapshot-Tabelle/Filter, lazy Browser/Suche, Quick Look, Auswahl von Datei/Ordner/Snapshot,
Zielauswahl, Fortschritt/Abbruch, sichere Konfliktregeln und fremde Quellidentitäten verbinden.
Recovery-Kit und Hilfe zur Wiederherstellung ohne MacKopia liefern. Pinning/Beschreibung und
explizit bestätigte destruktive Aktionen nur mit nachgewiesenem Daten-/Konfliktschutz.

**Prüfblock:** repräsentative Daten-/Metadatenfälle, Hashvergleich, Konflikte und Abbruch gegen Temp-Ziele;
ein integrierter Restore-UI-Durchgang, Package/Xcode/Format am Ende.
**Einstiegsstellen:** §6.4, §8.4, §9, §11.2, §12; bekannte Metadatenlimits aus Fixtures beachten.

### Phase 4 – Remote-Speicherziele vollständig anschließen

**Ergebnis:** S3, WebDAV und SFTP funktionieren vom Assistenten bis Backup und Restore.

S3 ist über denselben Dienst/Runtime-Pfad integriert; temporärer Lifecycle und offene Live-Nachweise in STATUS.md.
WebDAV ist über den freigegebenen Pipe-Transport in denselben Dienst-/Runtime-Pfad integriert und automatisiert geprüft;
Nächster Backend-Block danach: SFTP.

Pro Backend ein vollständiger größerer Arbeitsblock: Keychain/Transport, Erzeugen/Verbinden/Testen,
Auth-/Host-Key-UX, Runtime, Offline-/Fehlerbehandlung, Wiederverbindung und Restore.
Vorhandene S3-/WebDAV-Pipe-Spikes übernehmen, Secrets nie persistieren. Kein Neuschreiben bewährter
CLI-/TLS-Bausteine. Fehlender Zugang zu einem Backend blockiert nur dessen realen Nachweis;
keine fremden Konten oder Infrastruktur ohne Auftrag einrichten.

**Prüfblock:** Backend-Vertrag, Secret-Persistenznegativtest und ein kompletter temporärer Lifecycle
je geändertem Backend; vorhandene lange Spikes nur bei betroffenen Verträgen erneut ausführen.
**Einstiegsstellen:** §6.2–§6.4, §8, §9, SPIKE-D-SECRETS.md.

### Phase 5 – macOS-27-Erlebnis und Betriebsqualität

**Ergebnis:** Eine ruhige, vollständig bedienbare, ressourcenschonende native App mit sinnvollen Systemanbindungen.

UI- und Zustandswege über Fenster/Menüleiste/Tastatur vereinheitlichen; modernste passende SwiftUI-,
Observation-, Concurrency-, Network-, ServiceManagement-, UserNotifications-, Quick-Look- und
DiskArbitration-Anbindungen ohne Alt-OS-Fallbacks nutzen. App Intents/Spotlight nur für konkrete
freigegebene Aktionen, keine spekulativen neuen Entitlements/Buildphasen. Einstellungen und
Diagnose vervollständigen. Accessibility/DE-EN/Light-Dark-Kontrast zusammenhängend prüfen.
Mit Instruments echte Idle-CPU, Speicher, I/O und Updatefrequenz messen, dann begründet optimieren.
Keine große Umarchitektur bereits korrekter Module allein wegen einer neuen API.

**Prüfblock:** ein gebündelter UI-/Accessibility-/Performance-Audit mit reproduzierbaren Szenarien,
gezielte Regressionstests für gefundene Fehler; manuelle Nachweise separat mit Datum dokumentieren.
**Einstiegsstellen:** §4–§5, §11–§13, AGENTS.md §7.

### Phase 6 – Kontoloser Vertrieb und Release

**Ergebnis:** Ein heruntergeladenes macOS-27-arm64-Artefakt ist installierbar, aktualisierbar und dokumentiert.

Ad-hoc-Signaturen, Hardened Runtime, Packaging/DMG, Sparkle-EdDSA-Verifikation, Hilfe, Diagnose-Export
und Wiederherstellungs-Kit final verbinden. Quarantänisierten Download mit bewusster Gatekeeper-Freigabe,
Dienstregistrierung, Keychain-/FDA-Verhalten einschließlich Updates und reale Restore-Sicherheit prüfen.
Keine Developer-ID-/Notarisierungs-/Intel-/Alt-OS-Anforderung wieder einführen.

**Prüfblock:** einmal vollständige Release-Prüfung auf macOS 27/Apple Silicon: Package/Contracts,
Xcode Release/Artefaktsignaturen, Temp-Backend-Durchstiche und manueller Installations-/UI-/Hardware-Audit.
Nur tatsächliche Release-Risiken blockieren die Veröffentlichung; offene Nachweise sind kein Grund,
die übrige Implementierung in eine alte Phase zurückzustufen.
**Einstiegsstellen:** §8, §13, §16; RELEASE-CHECKLIST.md bei Beginn dieser Phase anlegen.

### Evidenz und Neustart ohne großen Chat-Kontext

STATUS.md benennt genau den nächsten größeren Auftrag samt Fertigkriterien und betroffenen Dateien.
IMPLEMENTIERUNG.md beschreibt den aktuellen verdrahteten Stand, nicht die gesamte Sessiongeschichte.
Prüfergebnisse enthalten Codezustand/Toolchain, geprüften Umfang, Ergebnis und Logpfad; nach relevanten
Codeänderungen sind ältere Ergebnisse historische Evidenz. Kein „grün“ für ungetestete neue Änderungen.
Lange Logs und alte Aufträge bleiben im Archiv und werden nur für eine konkrete offene Frage gelesen.

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

## 16. Produktentscheidungen und Vertrieb

1. Endgültiger App-Name (Markenprüfung; „Kopia“ im Namen ggf. mit dem Kopia-Projekt abstimmen) und Bundle-ID-Präfix.
2. **Verbindlicher Vertrieb ohne Apple-Konto (2026-10-25):** außerhalb des App Store, ohne
   Developer ID oder verpflichtende Notarisierung. Lokale Ad-hoc-Signaturen sichern Bundle-Integrität
   und XPC-Code-Identität. Bei regulärer Gatekeeper-Warnung gibt der Nutzer die App bewusst über
   „Datenschutz & Sicherheit → Dennoch öffnen“ frei; kein globales Abschalten von Gatekeeper.
   Keine Garantie für verwaltete Macs oder jede andere Blockierursache. Hilfe und Installationstest
   mit heruntergeladenem/quarantänisiertem Vertriebsartefakt sind Release-Gates.
   Referenz: [Apple: Apps auf dem Mac sicher öffnen](https://support.apple.com/102445).
   XPC-Code-Hash-Anforderungen verwenden Apples [LightweightCodeRequirements](https://developer.apple.com/documentation/lightweightcoderequirements).
   Hosting für Appcast/DMG (z. B. GitHub Releases) später festlegen.
3. Lizenzmodell der App (Open Source? Bezahl-App? Beeinflusst Sparkle-Feed und Website, nicht die Architektur).

---

## 17. Entscheidungslog

Neuere ausdrücklich ersetzende Entscheidungen haben Vorrang; alte Phasen-/Plattform-/Gate-Einträge sind historische Evidenz, keine aktuelle Arbeitsanweisung.

| Datum | Entscheidung | Grund |
|---|---|---|
| 2026-10-25 | Agentverwalteter Login-Keychain ohne Team/Access Group, Phase-1-XPC Version 2 und alleiniger manueller Runtime-Besitzer | Kontolose SecItem-Anbindung ohne neue Entitlements oder Secret-Dateien. Gebundene Volume-Auswahl, Serialisierung, Cleanup und begrenzte ereignisgesteuerte Zustandsantworten verbinden App und bestehende Engine; lokale Einrichtung/Editor/Status sind DE/EN verdrahtet. Automatik bleibt Phase 2. |
| 2026-10-25 | FDA-Freigabe verlangt frische Agent- und echte Kopia-Kind-Leseevidenz | [Kopia 0.23.1 readInputFile](https://github.com/kopia/kopia/blob/v0.23.1/cli/command_benchmark_compression.go) liest auch ohne ausgewählte Kompressionsmethoden. Probe ohne Repository/Dateilogging und mit 10-s-Frist; fehlende Safari-Testdatei blockiert konservativ. Keine pauschale TCC-Annahme und kein persistierter Freischalter; manuelle Installations-/Update-Zuordnung bleibt offen. |
| 2026-10-25 | Scheduler erfasst monotone Timer-Deadline vor dem Erzeugen des Tasks | Deterministischer Regressionstest reproduziert zusätzliche Verzögerung bei später Executor-Zuteilung. Absolute Deadline verhindert das Verschieben des Termins; Queue-Evidenztests warten auf den dauerhaften Queue-Abschluss, nicht nur auf den davor geschriebenen Historieneintrag. |
| 2026-10-25 | Ausschließlich macOS 27/Apple Silicon; neueste stabile Xcode-/Swift-/SwiftUI-Toolchain | Nutzerentscheidung: kein Legacy-/Intel-/Alt-OS-Support, aktuelle passende Systemanbindungen direkt nutzen. Verifiziert: Xcode 27.1, Swift 6.4, SDK 27; Sprachmodus bleibt Swift 6. Keine automatischen Beta-Upgrades oder spekulativen Framework-/Entitlement-Erweiterungen. |
| 2026-10-25 | Ergebnisorientierte Phasen, große autonome Aufträge und gebündelte Prüfung ersetzen Phase-0-Sperrkette | Nutzerentscheidung: weniger wiederholte Gesamtprüfungen und Mikroaufträge. Gezielte Compiler-/Sicherheits-/Regressionsdiagnose innerhalb eines Blocks vom Nutzer ausdrücklich bestätigt; Sicherheit betroffener Live-Funktionen und ehrliche Evidenz bleiben erforderlich. Kompakte STATUS-/Implementierungsdateien, historische Protokolle nur im Archiv. |
| 2026-10-25 | Vertrieb außerhalb des App Store ohne Apple-Developer-Konto verbindlich; ersetzt frühere Developer-ID-/Notarisierungs-Pflicht und bloßen Aufschub | Nutzerentscheidung: reguläre Gatekeeper-Warnung darf bewusst über „Dennoch öffnen“ freigegeben werden. Lokale Ad-hoc-Signaturen und Hardened Runtime; XPC pinnt exakte Code-Hashes aus dem geprüften Bundle statt Team-ID. Funktionstests für XPC, Registrierung, Keychain und FDA/TCC bleiben Pflicht; kein unsicherer Ersatztransport. |
| 2026-10-25 | Explizites Verify zunächst auf exakte Manifest-IDs des letzten erfolgreichen Planlaufs unter gemeinsamer Backup-Sperre begrenzen | Kopia 0.23.1 prüft ohne Ziele das gesamte Speicherziel. Vollständige Quell-UUID-Zuordnung, nichtleere Ergebnisarbeit und persistente Evidenz verhindern einen leeren oder fremden Vertrauensnachweis; automatische Auslösung folgt separat |
| 2026-10-25 | Abgeschlossene Verify-/Test-Restore-Ergebnisse in SQLite; Health liest Verify gemeinsam mit Laufhistorie | Prüfnachweise überleben Neustarts, sind an Plan und Speicherziel gebunden und enthalten nur feste Codes. Restore und Verify bleiben getrennt; ein gespeicherter Fehler darf nicht durch flüchtige Erfolgsbeobachtung verschwinden |
| 2026-10-25 | Plausibilitätswächter pinnt auffällige neue Quellmanifeste additiv per REST und übernimmt die ersetzte ID erst nach exaktem Nachlesen; verlorene Antwort führt zu keiner Write-Wiederholung | Kopia 0.23.1 `handleEditSnapshots`/`snapshot.UpdateSnapshot` erzeugt eine neue Manifest-ID. Historie/Restore müssen diese verwenden; vorhandene Pins bleiben erhalten. Schwellwert 1–100 Prozent, Standard/Fallback 50, exakter strikter Vergleich; Pinfehler bleiben kritisch sichtbar. Keine automatische Entpinnung oder Aufbewahrungssperre |
| 2026-10-25 | Health-Abfrage kombiniert dauerhafte Plan-/Zielhistorie mit typisierten aktuellen Beobachtungen; fehlende Prüfevidenz warnt, unlesbare Historie ist kritisch | Ohne Verify-Nachweis darf kein grünes Vertrauenssignal entstehen; getrennte Ein-/Ausgabe-Codes ermöglichen spätere lokalisierte Agent-/UI-Anbindung ohne Diagnose- oder Secret-Weitergabe |
| 2026-10-24 | Control-Shutdown über den eigenen Prozessabschluss nachweisen; Transportfehler nie pauschal als Erfolg behandeln | CI reproduziert Antwortverlust trotz Shutdown. Kopia 0.23.1 startet [OnShutdown asynchron](https://github.com/kopia/kopia/blob/v0.23.1/internal/server/server.go); [Serve und Prozessende](https://github.com/kopia/kopia/blob/v0.23.1/cli/command_server_start.go) können der Antwort zuvorkommen. Client bleibt unverändert fehlschließend; Integration verlangt Ende vor Cleanup und Exit 0. |
| 2026-10-24 | Manueller Dateisystem-Engine-Durchstich und GRDB 7.11.1 für dauerhafte Laufhistorie | Nutzer hat die GRDB-Abhängigkeit ausdrücklich freigegeben. §7.5 verbindet Queue/Config/Schutz, Policy-Abgleich, Server, Quellen und Historie; keine Agent-/TCC-Ausnahme. [Kopia 0.23.1](https://github.com/kopia/kopia/blob/v0.23.1/internal/server/api_snapshots.go) liefert ohne `all=true` nur nach Wurzel zusammengefasste Snapshots; vollständige Manifestliste verhindert falsche Fehlbewertung identischer Folgeläufe. Offene erweiterte Laufoptionen blockieren ausdrücklich. |
| 2026-10-24 | Agent-Aufträge als vollständige Ausführungsbatches gemäß §14; Phasen bleiben Abnahmegates | Nutzer hat den Vorschlag größerer zusammenhängender Läufe zur Umsetzung freigegeben; weniger wiederholte Kontext-/Prüf-/Hand-off-Schritte, vollständige Verdrahtung pro Batch |
| 2026-10-24 | Policy-Abgleich mit nichtpersistierender Vorschau, erneuten Leseprüfungen und Nachprüfung; kein Plan-Hash-Cache und keine automatische Rückschreibung | Kopia 0.23.1 unterstützt `resolve.updates`, aber keinen bedingten PUT. Vererbung/Ausschlüsse können unabhängig vom Plan wechseln; externe Schreibrennen bleiben ausdrücklich möglich. Scheduling bleibt unverändert; unwirksame Sollwerte blockieren |
| 2026-10-24 | macOS-Standardmuster Version 1 werden quellbezogen projiziert und an der Quellwurzel verankert | Verhindert Ausschlüsse gleichnamiger Library-Verzeichnisse außerhalb des übergebenen Home. Quellen innerhalb ausgeschlossener Home-Unterbäume liefern explizit `**`; optionale Regeln und Dateisystem-/Time-Machine-Auflösung bleiben separat. |
| 2026-10-24 | Eigenständige In-Memory-JobQueue mit FIFO, zusammengefassten Planaufträgen und kennungsgebundenem Abschluss | Wartende Aufträge erhalten den jüngsten Planstand; aktive Läufe bleiben unverändert. Ein Folgeauftrag pro aktivem Plan bleibt möglich, verspäteter Abschluss entsperrt keinen neueren Lauf. Ausführung, ConfigStore-Abgleich und Repository-Sperre bleiben separat. |
| 2026-10-24 | Reine Policy-Übersetzung liefert nur planverwaltete Sollwerte; aktivierte Ausschlussresolver müssen explizite Ergebnisse liefern | Kein unvollständiger PUT-Body und kein stiller Wegfall aktivierter macOS-/Time-Machine-Regeln. Reihenfolge und Negationen bleiben erhalten; Resolver, Vererbungssteuerung und Schreibabgleich folgen separat. |
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
| 2026-10-24 | Zeit-Scheduler mit injizierter monotoner Uhr und separater Kalenderberechnung | §7.3: Wochenzeiten mit `nextTime`/`first`, Mindestintervall nach Jitter eine Sekunde; neue Intervalle ohne Historie beginnen beim Start. Nachholen bleibt eine einzelne verzögerte Anforderung. Produktive Komposition bleibt separat. |
| 2026-10-23 | Zeitpläne nur in MacKopia, keine Kopia-Scheduling-Policies | Eine einzige Wahrheit, Trigger mit Bedingungen |
| 2026-10-23 | APFS-Snapshots, Hooks, Finder-Mount → Version 2 | Privilegierter Helper nötig bzw. nicht kritisch für 1.0 |
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
| 2026-10-24 | Expliziten Quellzugriffsadapter mit echten begrenzten Leseversuchen und separater geschützter Datenprobe ergänzt | §9: fehlende/unklare Probe blockiert, keine Inhaltsausgabe oder rekursive Lesbarkeitsgarantie. Konservativer experimenteller FDA-Nachweis für alle Quellen; Standard bleibt unbekannt, bis signierte Agent-/Kindprozess-Zuordnung geprüft ist. |
| 2026-10-24 | Nativen Policy-Lesepfad einschließlich effektiver Auflösung gegen Kopia 0.23.1 geprüft | §7.1: vollständige Quellidentität, lesender POST ohne Updates/Zeitpläne, fehlende Definition nur bei HTTP 400 + NOT_FOUND; getrennte definierte/effektive Werte und Ursprünge. Decodable-Projektionen sind keine Schreibmodelle. |
| 2026-10-24 | Time-Machine-Ausschlüsse explizit, quellgebunden und begrenzt auflösen; bei Teilfehlern kein Ergebnis | §10: Tiefe 3, 10.000 Einträge, kooperativ 10 s, höchstens 60 s wiederverwendbar; keine automatische Policy-Anwendung und keine harte Unterbrechung blockierender I/O. |
| 2026-10-24 | Queue über ConfigStore und geschützten Operationskoordinator freigeben | §7.2/§7.5: aktueller Plan bei Entnahme, erneute Gleichheitsprüfung vor Callback und Queue-Abschluss nach Cleanup; keine produktive Agent-Verdrahtung. |
| 2026-10-24 | Vollständige lokale Policy-Definition verlustfrei für den späteren Schreibabgleich vorbereiten | §7.1: unbekannte Felder/Zahlentokens erhalten, kein HTTP-Writer. Kopia 0.23.1 vererbt leere Ignore-Listen und maxFileSize 0 weiter; effektive Zielwerte müssen separat validiert werden. |
| 2026-10-24 | Vollständige Policy-Definitionen über den vorhandenen gepinnten Lesetransport an die exakte Quelle binden | §7.1: JSON-Dokument und Fehler liegen bei den Kopia-Wire-Modellen in KopiaServer; Engine-Merge erhält unbekannte Felder und Zahlentokens. 1 MiB bereits beim Stream begrenzen; kein Revisionstoken, Writer oder automatischer Lauf. |
| … | *(Weitere belegte Entscheidungen hier eintragen)* | |

| 2026-10-24 | Retry: drei Wiederholungen zusätzlich zum ersten Lauf | Nutzer bestätigt 1, 5 und 15 Minuten; maximal vier Läufe je Kette. Monotone Timer, frische Konfigurationsprüfung und kein Retry bei unbekanntem Fehler. |

| 2026-10-24 | Zeitbegrenzte Pausen: absoluter Endzeitpunkt mit monotonem Timer | §6.6: Kalenderdatum für morgen 08:00, eindeutige Timerkennung, Wake-/Uhrzeitabgleich; Timerfehler hält Pause sichtbar statt unbeabsichtigt fortzusetzen. Laufzeitkomposition und Persistenz separat. |

| 2026-10-25 | Gemeinsame automatische Package-Laufzeit vor Agent-Komposition | §7.5: ein serieller Engine-Besitzer, separate Queue-Beobachtung, gejointe Admission-Worker, planbezogene Evidenzversionen und terminaler Monitoring-Shutdown. Agent-/XPC-Freigabe und persistente Zustände bleiben separat. |

| 2026-10-25 | Idle-Sleep-Schutz in gemeinsamer Engine-Ausführung | §7.4/§7.5: native IOPM-Assertion vor Serverstart, Freigabe nach Cleanup mittels defer mit atomarem Deinit-Fallback; Erwerbsfehler blockiert den Lauf. Kein Display-/Explizit-Sleep-Verbot. |

| 2026-10-25 | Automatische Scheduler-Anker aus dauerhafter Erfolgshistorie | §7.3/§7.5: jüngster erfolgreicher Start je Plan und Ziel bis jetzt; vollständige Historie, fehlgeschlagene/offene Läufe ausgeschlossen; Lesefehler blockiert Start. Explizite Anker bleiben möglich. |

| 2026-10-25 | Pausensperren vor Queue-Freigabe dauerhaft sichern und beim Start restaurieren | §6.6/§7.5: eigene versionierte Datei unter bestehendem Konfigurationsschutz; Zeitpunkte absolut, Timerfehler bleiben manuell lösbar. Speicherfehler verriegelt Ausführung; Shutdown erzeugt keine neue dauerhafte Pause. Wiederaufnahme alter Arbeit separat. |

| 2026-10-25 | Expliziter Live-Konfigurationsreload innerhalb der automatischen Package-Laufzeit | §7.5: Queue-Entnahme während Abgleich gesperrt; geänderte Pläne/Ziele mit Cleanup abbrechen, unveränderte aktive Arbeit und Pausen erhalten. Frische Trigger-Evidenz, Retry-Reset und Historienanker; Abgleichfehler beenden Laufzeit. Kein Dateiwächter und keine produktive Agent-Freigabe. |

| 2026-10-25 | Dauerhafte Queue-Absicht zusammen mit Pausen und transaktionale Historien-Crash-Abstimmung | §6.6/§7.5: Schema 2 mit Migration von Schema 1; neue Laufkennungen und frische Schutzprüfungen nach mindestens zwei Minuten. Stopp entfernt Absicht vor Abbruch; Historie behauptet keinen Erfolg nach Crash. Einzelner Runtime-Besitzer Voraussetzung; keine gemeinsame Transaktion zwischen SQLite und Steuerdatei. |

| 2026-10-25 | Expliziter geschützter Test-Restore mit begrenzter Zufallsauswahl und SHA256-Vergleich | §7.6: Auswahl aus Root-Objekten der letzten vollständigen erfolgreichen Laufhistorie; nur unveränderte reguläre Originale unter 50 MB. Keine geeignete Datei oder Quelländerung erzeugt keinen Erfolg. Private 0700/0600-Temp-Ausgabe mit atomarem Schreiben und Cleanup unter Reservierung; separate dauerhafte Test-Restore-Evidenz, automatische Termine folgen. |

| 2026-10-25 | Automatischer Test-Restore als serielle Nacharbeit eines erfolgreichen Backups | §7.6: dauerhafte Fälligkeit statt flüchtiger Timer, Standard 30 Tage; warnungsfreie Läufe, gemeinsame Repo-Reservierung, Abbruch samt Cleanup bei Laufsteuerung. Unentscheidbare Stichproben erzeugen keinen Termin, Prüffehler keine Backup-Retries. Produktive Agent-Komposition separat. |
| 2026-10-25 | Wöchentliche automatische Verify-Prüfung als serielle Backup-Nacharbeit | §7.6: getrennte dauerhafte Verify-/Restore-Fälligkeit, vorhandene geschützte Engine, gemeinsamer Abbruch und Cleanup. Monatliche Stufe benötigt eigenen dauerhaften Stufennachweis und folgt separat. |
| 2026-10-25 | Monatliche Verify-Stufe aus dauerhaft gespeichertem Dateianteil | §7.6: mindestens 10 Prozent alle 30 Tage, vorrangig vor gleichzeitig fälliger Wochenprüfung; größere explizite Prüfungen zählen mit. Wochenprüfungen verschieben den Monatstermin nicht. Legacy ohne Anteil bleibt lesbar, zählt aber nicht monatlich; automatische Health-Gültigkeit weiterhin sieben Tage. |
| 2026-10-25 | Geschützte lesende Wartungsauswertung vor der Ausführungsanbindung | §7.6: gemeinsamer Repo-Schutz, exakte stabile Owner-Identität, typisierter Full-Termin; keine Owner-Änderung oder Wartungsausführung durch die Beobachtung. Echter gepinnter CLI-Vertrag im temporären Speicherziel geprüft. |
| 2026-10-25 | Fällige Full-Wartung mit frischer Owner-/Terminprüfung unter gemeinsamer Reservierung | §7.6: reguläres `maintenance run --full` ohne Force-/Safety-Overrides; Konfigurationsabgleich, SleepAssertion und Abbruch-Cleanup wie Backup. Nur temporäres Testziel live geprüft; automatische Nacharbeit und dauerhafte Evidenz separat. |


| 2026-10-25 | Phase 2: gemeinsame produktive Automatik statt separater manueller Engine | §7.5/§12: LocalBackupService besitzt die einzige Runtime; manuelle und automatische Läufe, persistente Pausen/Queue-Recovery, Health und serielle Nacharbeit über denselben Schutzpfad. XPC Version 3; Steuer-UUID-Sperren verhindern Folgeläufe während Abbruchbereinigung. |
| 2026-10-25 | Additive Mitteilungseinstellung und wartungsbezogene Evidenz | §7.2/§7.6/§11.4: ältere Konfigurationen lesen notificationsEnabled=false; Agent fordert Berechtigung nur nach expliziter Aktivierung an. Dauerhafte Wartungsergebnisse in eigener SQLite-Tabelle, Restore-Fehler kritisch. Routineerfolge bleiben still; Problemlimit pro Plan 24 Stunden. |
| 2026-10-25 | Optionales sicheres Auswerfen nach serieller Backup-Nacharbeit | §7.4/§7.6: ausschließlich lokale abnehmbare UUID-gebundene Volumes, reguläre DiskArbitration-Optionen, kein Force. Gemeinsame Repo-Sperre bis zur nativen Rückmeldung. Nur Ablehnung falscher/nicht abnehmbarer Volumes automatisiert geprüft; Hardware-Audit separat. |
| 2026-10-25 | Phase 3: Restore in neue private Ordner, dienstbesessene Operationen und XPC Version 4 | §11.2/§12: UI-Auswahl über Snapshot-ID/Namenskomponenten, frische Manifeste/Abstammung, gemeinsame Repo-/Automatik-Sperren und Ziel-/Ausgabe-UUID-Schutz. Kein Originalquellenzugriff; keine Überschreib-/Originalort-Option ohne zusätzlichen Konfliktnachweis. Temp-Integration bestätigt Inhalte, Metadaten, Konfliktablehnung, Abbruch und fremde Identitäten. |
| 2026-10-25 | Kopia 0.23.1: Restore mit Manifest/Namenspfad und exakten Unicode-Bytes | Rohe Dateiobjekte verlieren Namen/Metadaten; Go unterscheidet NFC/NFD, Swift-Gleichheit nicht. Dienst verwendet gespeicherte Namen und verweigert mehrdeutige äquivalente Einträge. Kopia-Edit ersetzt Manifest-ID; Nutzer-Pin ist getrennt von Sicherheits-Pins. |
| 2026-10-25 | Begrenzter lazy Restore-Browser, Quick Look und Recovery-Kit ohne Passwort | §8.4/§11.2: explizite Suchgrenzen; Cache-Sitzung privat und beim Schließen bereinigt, Crashreste als offene Grenze dokumentiert. Kit über nativen Druck-/PDF-Dialog ohne Secret-Rückgabe. Manuelle Druck-/DE-EN-/A11y-Abnahme separat. |

| 2026-10-25 | Phase 4/S3: secretfreier Create-only-Bootstrap, Keychain-Envelope und XPC Version 5 | §6.2/§8/§9: eigene atomare Connection ohne AWS-Felder; Credentials nur an Kind-Environment, frischer Format-Blob statt Cache als Auth-Evidenz, geprüfter Credential-Ersatz. Bestehende Runtime/Restore/Verify/Wartung gemeinsam; HTTPS und ausschließlich lokales 127.0.0.1-HTTP-Fixture. Object Lock und reale Provider-Abnahme separat. |

| 2026-10-25 | Phase 4/WebDAV: Keychain-Envelope und frische native Pipe bis Backup/Restore, XPC Version 6 | §6.2/§8/§9: Create-only ohne Connection, Connect ohne Konfigurationsmutation; explizite Cache-Kapazitäten, Balanced/zstd, Owner-Erhalt, frischer Format-Read für Zugang/Credential-Ersatz. HTTPS; HTTP nur literales 127.0.0.1 zum temporären Test. Keine neuen Abhängigkeiten/Entitlements; reale Anbieter-/UI-/Keychain-Abnahme separat. |

---

## Anhang A – Beobachtung auf dem Entwicklungsrechner

Auf dem Entwicklungsrechner existiert bereits eine Kopia-Standardkonfiguration mit einem Dateisystem-Repository unter
`/Volumes/TRESOR` (Laufwerk zum Zeitpunkt der Analyse nicht verbunden). Konsequenzen:
- MacKopia darf diese Konfiguration **nie** verändern (eigene `--config-file`-Pfade, Abschnitt 5.1).
- Der Import-Assistent (Phase 4) muss genau diesen Fall abdecken: bestehende Config erkennen, Repository-Parameter übernehmen,
  Passwort abfragen (ggf. aus Kopias eigenem Keychain-Eintrag – nur nach Nutzerzustimmung), Volume-UUID beim nächsten Anstecken binden,
  bestehende Snapshot-Identität (`user@host`) übernehmen, damit die Historie nahtlos weiterläuft.
- Gutes reales Testszenario für Phase 4/6.
