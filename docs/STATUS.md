# Status & nächster Auftrag

Stand: 2026-10-26. Einstieg: AGENTS.md, dieser Status, PROJEKT.md §14 und IMPLEMENTIERUNG.md.
Historische Evidenz bleibt im [Archiv](history/README.md).

## Aktuelle Produktphase

**Phase 5 begonnen: Vorschau-Datenschutz und native Status-/Bedienkonsistenz verbessert.**
Phase 1–4 integriert; SFTP-/WebDAV-Reviewhistorie: [PR #6](https://github.com/drhdevorg/mackopia/pull/6),
[PR #5](https://github.com/drhdevorg/mackopia/pull/5). Basis auf `main`: `ebe1aaf`.
Aktueller Arbeitsbranch: `codex/p5-native-quality`. Phase 5 ist noch nicht abgeschlossen.

## In progress

| Agent | Auftrag | Branch | Dateien/Module |
|---|---|---|---|
| Codex | Phase-5-Checkpoint; Live-Audit wartet auf Entsperren des Macs | `codex/p5-native-quality` | App/, Agent/, BackupEngine, Tests, docs/ |

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
- Xcode `build test`: **Exit 65**, Test-Runner verbindet sich nicht, Timeout nach 832 s;
  Log `/tmp/mackopia-p5-xcode.log`. Keine Compilerwarnungen; IDE-Launch-/Daemon-Fehler.
  Eigenständiger Xcode-Build **erfolgreich**, `/tmp/mackopia-p5-build.log`; kombinierter Lauf nicht grün.
- Gezielte Launcher-Diagnose: gebautes `MacKopiaTests.xctest` per `xcrun xctest` ausgeführt:
  **4 Bundle-/Signaturtests bestanden**, 0,063 s; `/tmp/mackopia-p5-bundle-direct.log`.
- Strikter Swift-Format-Lint und `git diff --check` sauber. App 246 / Agent 126 Katalogeinträge,
  kein nichtleerer Schlüssel ohne Englisch; neue Restore-Zeile DE/EN.
- Erster Compile-Versuch: fehlender BackupDomain-Import, vor obiger Vollprüfung korrigiert.
- Live-UI: Computer Use meldet gesperrten Mac; automatisches Entsperren nicht möglich.
  Nutzer um Entsperren gebeten. Keine Screenshots/VoiceOver-/Instruments-Messwerte vorhanden.
  `xctrace list templates` erfolgreich; das ist kein Performance-Nachweis.
- Vorheriger SFTP-Abschluss und einmalige WebDAV-Prüfablehnung samt unverändert erfolgreicher Diagnose:
  [Phase-4-Evidenz](history/STATUS-Phase4-SFTP-Abschluss-2026-10-26.md). Im aktuellen Vollauf WebDAV grün.

## Offene Live-Nachweise und Grenzen – kein globaler Entwicklungsstopp

| Nachweis | Betroffene Funktion | Exakte nächste Aktion / Besitzer |
|---|---|---|
| Reales WebDAV/TLS/Anbieter | Provider-Kompatibilität | Nutzer stellt explizit entbehrlichen HTTPS-Testordner bereit; Agent prüft Create/Connect/Backup/Restore/Credential-Wechsel |
| Reales S3/IAM/TLS/Token-Ablauf | Provider-Kompatibilität | Nutzer stellt explizit entbehrlichen Bucket/Präfix bereit; Agent prüft Create/Connect/Backup/Restore und Credential-Wechsel |
| S3 Object Lock und spezifische Auth-Diagnose | Optionale Provider-Funktionen/UX | Eigenen Provider-Vertrag nachweisen; aktuell nicht im Assistenten, Fehler bleiben sanitisiert und führen zu Netzwerk-/Zugangsprüfung |
| Installierter Dienst/XPC | SMAppService/Peer-Vertrauen | Nutzer aktiviert gebaute App/Dienst; Agent prüft positive/negative registrierte Peers |
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
Nutzer entsperrt Mac; Agent öffnet gebautes Bundle über Computer Use. Fenster/Menüleiste/Shortcuts,
Fehleraktionen/Remote-Assistenten prüfen; DE/EN, Light/Dark/Kontrast, minimales Fenster, Tastatur/VoiceOver
mit Screenshots erfassen und Instruments Idle-CPU/Speicher/I/O/Updatefrequenz messen.
Bekannte unabhängige Bedienlücken: Quellen-Drag-and-drop, Entf/Undo, Menüleisten-Restore-Navigation und
Fehleraktionen prüfen/integrieren; keine spekulativen Frameworks/Entitlements. Registrierung/FDA/Keychain
nur mit bewussten nötigen Systemfreigaben; reale Provider/Hardware bleiben separat.
Fertig: belegter integrierter Audit, behobene Befunde mit Tests, relevante Prüfungen und kompakte Übergabe.
Name/Bundle-Präfix MacKopia / com.example.MacKopia; Lizenzmodell offen.
