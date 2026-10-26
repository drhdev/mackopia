# Status & nächster Auftrag

Stand: 2026-10-26. Einstieg: AGENTS.md, dieser Status, PROJEKT.md §14 und IMPLEMENTIERUNG.md.
Historische Evidenz bleibt im [Archiv](history/README.md).

## Aktuelle Produktphase

**Phase 5: Dienstregistrierung und Editorzustand live korrigiert; Temp-Einrichtung belegt.**
Phase 1–4 integriert; SFTP-/WebDAV-Reviewhistorie: [PR #6](https://github.com/drhdevorg/mackopia/pull/6),
[PR #5](https://github.com/drhdevorg/mackopia/pull/5). Basis auf `main`: `ebe1aaf`.
Aktueller Arbeitsbranch: `codex/p5-native-quality`, [Draft PR #7](https://github.com/drhdevorg/mackopia/pull/7).
Produktionsbasis: `70309cb`; aktuelle Live-Fixes auf obigem Branch. Phase 5 bleibt offen.

## In progress

| Agent | Auftrag | Branch | Dateien/Module |
|---|---|---|---|
| Codex | Phase-5-Live-Audit; Registrierungsrückmeldung und Sidebar-Trunkierung | `codex/p5-native-quality` | App/, Agent/, BackupEngine, Tests, docs/ |

## Verbindliche Entscheidungen

- macOS 27.x, natives arm64; Xcode 27.1 (27A9275), Swift 6.4 / Sprachmodus 6, SDK 27.
- Ad-hoc-Vertrieb/Hardened Runtime; unveränderte Entitlements/Dependencies/Buildphasen und Kopia 0.23.1.
- Agent besitzt Runtime, Schlüsselbund und Kopia; App nur über authentifiziertes XPC, Version 7.
- S3/WebDAV/SFTP-End-to-end: Create/Connect, geprüfter Credential-Ersatz, Backup/Verify/Restore.
- WebDAV/SFTP-Runtime-JSON nur im RAM: frische anonyme Pipe, geschütztes Symlink-Verzeichnis, gemeinsame Sperre.
- SFTP: bewusste öffentliche Host-Key-Freigabe, SHA256-Pin, geschützte known_hosts; Schlüssel im Keychain.
  RSA-PEM im RAM normalisiert; SSH-Passwort/verschlüsselte OpenSSH-Schlüssel weiterhin nicht freigegeben.
- Create-only; Connect erhält fremden Wartungs-Owner. Credential-Ersatz erst nach frischer Auth-Probe.
- Neue Pläne manuell bis Terminwahl; Mitteilungen aus; Eject nie mit Force.
- Restore nur in neuen privaten UUID-Ordner (0700), Overwrite aus, keine Originalquelle nötig.
- Quick-Look-Startup-Cleanup gemäß PROJEKT.md §11.2/§17; Fehler sperren nur neue Vorschauen.

## Implementiert und verdrahtet

- Phase 1–4: gemeinsamer Dienst/Queue/Gate, UUID-/FDA-Schutz, Automatik/Pausen/Recovery,
  Health/Nacharbeit, Restore-Katalog/Browser/Suche/Quick Look und Remote-Assistenten DE/EN.
- `RestorePreviewCache`: beim Dienststart/vor Vorschau nur eigene reguläre 0700-UUID-Sitzungen im
  symlinkfreien 0700-Cache entfernen; unbekannte Namen/Symlinks erhalten. Startfehler ohne Pfade loggen.
  Wiederholtes `start()` entfernt keine laufende Sitzung; fehlender Root erzeugt keine Verzeichnisse.
- Menüleiste: laufender Restore mit Abbruchaktion, bestimmter Backup-Fortschritt falls verfügbar,
  Warnsymbol auch für Health-Warnung/nicht verfügbaren Dienst. Kein neuer IPC-Vertrag.
- ⌘. nutzt denselben Busy-Guard wie Toolbar; Fortschritt/Pausenmenü/Quelle entfernen mit A11y-Labels.
- Detailbefunde und reproduzierbarer Live-Wiederaufnahmeweg:
  [Phase-5-Audit](history/Phase5-Qualitaetsaudit-2026-10-26.md).

## Prüfung dieses Codezustands

- Xcode 27.1 (27A9275), Swift 6.4, arm64; finaler Produktionscode auf obigem Branch.
- Package-Vollsuite: **557 Tests / 105 Suites bestanden**, echte temporäre lokale/S3-/WebDAV-/SFTP-
  und Restore-Integration; 164,4 s. Log `/tmp/mackopia-p5-package.log`, keine Compilerwarnungen.
- 4 neue Cache-/Dienststarttests bestanden: sichere Entfernung, Symlink-/Dateierhalt, unsicherer Root,
  fehlender Root, wiederholter Dienststart. Bestehender echter Preview-/Restore-Lifecycle ebenfalls grün.
- Xcode-Wiederaufnahme: **`build test` erfolgreich, 4 Bundle-/Signaturtests bestanden**, keine
  Compilerwarnungen; unveränderter Produktionscode, Xcode 27.1 / arm64.
  Log `/tmp/mackopia-p5-build-test-resume.log`, Ergebnis `Run-MacKopia-2026.10.26_15-02-06-+0100.xcresult`.
- Zuvor `test-without-building` ebenfalls erfolgreich: 4 Tests, 0,207 s;
  `/tmp/mackopia-p5-test-resume.log`. Beide Wiederaufnahmen außerhalb der Sandbox mit
  `-parallel-testing-enabled NO`; Ursache des früheren Daemon-Verbindungs-Timeouts nicht isoliert.
  Keine Scheme-/Signatur-/Entitlement-Änderung nötig. Historischer Exit 65 bleibt im früheren Log
  `/tmp/mackopia-p5-xcode.log`; direkter damaliger Bundle-Lauf ebenfalls 4 Tests grün.
- Das Xcode-Testziel enthält Bundle-/Signaturtests, noch keine automatisierten XCUITests.
- Strikter Swift-Format-Lint und `git diff --check` sauber. App 246 / Agent 126 Katalogeinträge,
  kein nichtleerer Schlüssel ohne Englisch; neue Restore-Zeile DE/EN.
- Erster Compile-Versuch: fehlender BackupDomain-Import, vor obiger Vollprüfung korrigiert.
- Live-UI wieder erreichbar; Nutzerfreigabe für Dienst/Temp-Workflow liegt vor. Registrierung nach
  `.notFound`-Fix erfolgreich, XPC verbunden. Offline/⌘R/⌘,/Sidebar und ⌘N live geprüft.
- Finale Package-Suite **559 Tests / 105 Suites grün**, seriell 289,8 s; TLS-1.3-Python explizit gesetzt.
  `/tmp/mackopia-p5-live-package-serial.log`. Parallele Remote-Fehler bleiben im Audit dokumentiert.
- Finaler Editor-/Registrierungsstand: **Xcode build test grün**, 4 Bundle-/Signaturtests,
  `/tmp/mackopia-p5-editors-xcode-final.log`, keine Compilerwarnung. Format/Diff sauber.
- Neue Regression: `.notFound` darf explizite Registrierung nach Signaturprüfung erreichen;
  zunächst rot, anschließend grün; echte Systemfehler bleiben typisiert.
- Neue Sheet-Hosts erhalten Entwürfe bei Verbindungsevents; Name/Ziel nach Quellenwahl live erhalten.
  ⌘N ersetzt Standard-Neues-Fenster-Befehl. Deutsche Sidebar ohne bisherige Trunkierung.
- Instruments-App-Idle 30 s: CPU Ø 0,211 %, Peak 4,975 %, Footprint 58,42–58,55 MiB, App-I/O 0 B/s.
  Vorläufige Messung, kein Agent-/Last-/60-s-Nachweis; Trace und Grenzen im Audit.
- Temp-Ziel live eingerichtet; ⌘B vom fehlenden FDA-Nachweis sicher blockiert, passende Fehleraktion.
  Nutzer lehnt FDA-Freigabe ausdrücklich ab; noch kein Live-Backup/-Restore.
- Vorheriger SFTP-Abschluss und einmalige WebDAV-Prüfablehnung samt unverändert erfolgreicher Diagnose:
  [Phase-4-Evidenz](history/STATUS-Phase4-SFTP-Abschluss-2026-10-26.md). Im aktuellen Vollauf WebDAV grün.

## Offene Live-Nachweise und Grenzen – kein globaler Entwicklungsstopp

| Nachweis | Betroffene Funktion | Exakte nächste Aktion / Besitzer |
|---|---|---|
| Native Verbindung wieder erreichbar, Agent-Fensteraufruf einmal Timeout | UI-/A11y-/Performance-Audit | Agent: App-Fenster weiter auditieren; MenuBarExtra separat öffnen |
| Reales WebDAV/TLS/Anbieter | Provider-Kompatibilität | Nutzer stellt explizit entbehrlichen HTTPS-Testordner bereit; Agent prüft Create/Connect/Backup/Restore/Credential-Wechsel |
| Reales S3/IAM/TLS/Token-Ablauf | Provider-Kompatibilität | Nutzer stellt explizit entbehrlichen Bucket/Präfix bereit; Agent prüft Create/Connect/Backup/Restore und Credential-Wechsel |
| S3 Object Lock und spezifische Auth-Diagnose | Optionale Provider-Funktionen/UX | Eigenen Provider-Vertrag nachweisen; aktuell nicht im Assistenten, Fehler bleiben sanitisiert und führen zu Netzwerk-/Zugangsprüfung |
| Registrierter Dienst/XPC positiv verbunden | SMAppService/Peer-Vertrauen | Agent: negative registrierte Peers und Update-/Neustartpfad prüfen; positive Aktivierung live belegt |
| Login-Keychain/TCC/FDA/Updates | Produktive Secrets/geschützte Quellen | Nutzer + Agent: nur Temp-Ziel, ggf. FDA bestätigen; echte Credential-Aktualisierung und Update-ACL prüfen |
| Safari-Testdatei fehlt oder ist >1 MiB | Konservative FDA-Erkennung | Zugriff gesperrt lassen; begrenzte alternative Kind-Leseprobe entwickeln/nachweisen |
| Reales Unmount/Eject/Abziehen | Hardwarefunktion | Nutzer + Agent: entbehrliches USB-Testvolume, UUID-Wechsel/Veto/Abbruch; kein Force |
| Native Mitteilungen/Aktionen | Zustellung | Nutzer aktiviert am registrierten Dienst; Agent prüft Zustellung/Retry/Details mit Temp-Plan |
| Restore-/Remote-UI-Durchgang und Kit/PDF | Fenster, Quick Look, Druck | Agent + Nutzer: lokales Fixture/Temp-Backup, Fehler/Abbruch/Credential-Sheet und PDF-Layout prüfen |
| DE/EN, Light/Dark/Kontrast, Tastatur/VoiceOver | UI-/Releasequalität | Phase 5/6: Screenshots/minimales Fenster und A11y-Audit; bisher Code/Previews/Katalog/Build |
| Große Kataloge/Verzeichnisse | Restore-Browser | >128 Quellen/1.000 Snapshots/8 MiB bzw. >2.000 Einträge blockieren; Pagination vor größerer Freigabe |
| Gatekeeper/Updates, Checkpoint 45 statt 15 Minuten | Release | Phase 6: Installationsartefakt prüfen; Checkpoint-Produktentscheidung treffen |
| Reales SFTP/SSH/Host-Key | Provider-Kompatibilität | Nutzer stellt entbehrlichen Testordner und öffentlichen Host-Key über vertrauenswürdigen Kanal bereit; Agent prüft Create/Connect/Backup/Restore/Schlüsselwechsel |
| Einmalige WebDAV-Verifikationsablehnung im Vollauf | Prüfevidenz unter paralleler Last | Bei erneutem Auftreten sanitisierte Prozess-/Prüfzähler und Fixture-Zustand erfassen; erster Fehler und isolierte erfolgreiche Diagnose oben |


## Nächster vollständiger Coding-Auftrag

**Phase 5 fortsetzen: zusammenhängender UI-/Accessibility-/Performance-Audit mit Temp-Workflow.**

Einstieg: PROJEKT.md §4–§5, §11–§14 Phase 5, AGENTS.md §7, IMPLEMENTIERUNG.md und Audit oben.
Native Verbindung und Dienstregistrierung sind positiv belegt; Freigabe für Temp-Workflow liegt vor.
Temp-Root: `/private/tmp/mackopia-live-audit-xp05r3_k`. Fenster/Menüleiste/Shortcuts,
Fehleraktionen/Remote-Assistenten prüfen; DE/EN, Light/Dark/Kontrast, minimales Fenster, Tastatur/VoiceOver
mit Screenshots erfassen und Instruments Idle-CPU/Speicher/I/O/Updatefrequenz messen.
FDA-Freigabe abgelehnt; geschützten Live-Lauf erst nach einer neuen ausdrücklichen Freigabe fortsetzen.
Bekannte unabhängige Bedienlücken: Quellen-Drag-and-drop, Entf/Undo, Menüleisten-Restore-Navigation und
Fehleraktionen prüfen/integrieren; keine spekulativen Frameworks/Entitlements. Registrierung/FDA/Keychain
nur mit bewussten nötigen Systemfreigaben; reale Provider/Hardware bleiben separat.
Fertig: belegter integrierter Audit, behobene Befunde mit Tests, relevante Prüfungen und kompakte Übergabe.
Name/Bundle-Präfix MacKopia / com.example.MacKopia; Lizenzmodell offen.
