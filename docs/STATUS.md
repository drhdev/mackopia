# Status & nächster Auftrag

Stand: 2026-10-25. Kompakter Neustarteinstieg; historische Evidenz bleibt im Archiv.
Zuerst AGENTS.md, diesen Status, PROJEKT.md §14 und IMPLEMENTIERUNG.md lesen.

## Aktuelle Produktphase

**Phase 3 ist im lokalen Dienst und der App integriert und automatisiert geprüft.**
Backups sind ohne Originalquelle auffindbar und in neue private Ordner wiederherstellbar.
Live-UI-/Druck-/Systemabnahme bleibt separat offen. Nächster Coding-Auftrag: Phase 4, zuerst S3.

## In progress

| Task | Agent / person | Branch | Modules / files touched | Started |
|---|---|---|---|---|

## Verbindliche Entscheidungen

- macOS 27.x, natives arm64; Xcode 27.1 (27A9275), Swift 6.4 / Sprachmodus 6, SDK 27.
- Kontoloser Ad-hoc-Vertrieb mit Hardened Runtime; keine neuen Entitlements/Abhängigkeiten/Buildphasen.
- Keychain ausschließlich im Agent, Standard-App-ACL; keine Team-/Access-Group-Pflicht und kein Hintergrunddialog.
- FDA verlangt frische Agent- UND Kopia-Leseevidenz; fehlende Safari-Testdatei blockiert konservativ.
- Neue Pläne sind bis zur Terminwahl manuell; Mitteilungen optional, Standard aus; Eject nie mit Force.
- Restore: neuer privater UUID-Ordner (0700), alle Overwrite-Schalter aus, keine Originalort-/Überschreiboption.
  Erweiterte Varianten benötigen vor Freigabe einen eigenen Konflikt-/Symlinknachweis und bewusste Bestätigung.
- Snapshot-/Namensauswahl statt Client-Objekt-IDs; exakte gespeicherte Unicode-Namen an Kopia zurückgeben.
- Nutzer-Pin getrennt von automatischen Sicherheits-Pins. Kopia-Edit ersetzt Manifest-ID; Katalog neu laden.
- Recovery-Kit über nativen Druck-/PDF-Dialog ohne Passwort. Quick Look maximal 50 MB, privater Sitzungscache.
- Normative Architektur und Entscheidungen: PROJEKT.md §6.4, §8.4, §9, §11.2, §12 und §17.

## Implementiert und verdrahtet

- Phase-1/2-Basis: ein `LocalBackupService` mit einer `AutomaticBackupRuntime`, gemeinsamer Queue/Gate,
  Keychain, UUID-/FDA-Schutz, Scheduling, Retry/Pausen/Recovery, Health, Verify/Test-Restore/Wartung.
- `LocalServiceRestore`: Katalog/Browser/Suche, dienstbesessener Restore-Task mit UUID, Fortschritt/Abbruch.
  Laufsteuerung und Gate bleiben bis Server-Shutdown/Reaping reserviert. Originalquellen werden nicht geprüft.
  Bei angehaltener Automatik bleibt Restore über dieselbe Repo-Sperre möglich; normale Backups bleiben geschützt.
- `RestoreBrowser`: vollständige Benutzer-/Rechner-/Quellidentität, frische Manifeste und Verzeichnisabstammung.
  Mehrdeutige NFC/NFD-Namen, Traversal und Symlink-Abstieg werden abgewiesen; Suchgrenzen sichtbar.
- `RestoreDestination`: frische UUID/Kapazität, keine Ausgabe in registrierte Speicherziele, privater neuer Ordner.
  Fehler/Abbruch behalten Teilresultate; SUCCESS mit übersprungenen Dateien/ignorierten Fehlern gilt als Fehlschlag.
- XPC Version 4: Browse/Search/Edit/Restore/Cancel/Preview/ClearPreview und begrenzte Restore-Projektion.
  Signing-/Code-Hash-Pinning, Request-/Antwortgrenzen und Secrets-Regeln bleiben erhalten.
- App: sortierbare Snapshot-Tabelle, Plan-/Quell-/Rechnerfilter, lazy Browser, Dateinamensuche, Auswahl von
  Snapshot/Ordner/Datei, Ziel-Sheet (Downloads voreingestellt), Abbruch, Finder und Leertaste/Quick Look.
  Beschreibung/Nutzer-Pin editierbar; ⌘R öffnet Restore, ⌘. stoppt auch Restore. DE/EN, sichere Mock-Previews.
- Recovery-Kit jederzeit im Restore-Bereich, Angebot nach Einrichtung; Typ/Ziel/Identität/Version/Datum und
  CLI-Anleitung ohne MacKopia. Keine Passwort-Rückgabe; Druck/PDF noch nicht manuell abgenommen.
- Branch: `codex/p3-restore-recovery`, Basis `main` bei `adb1914` (Phase-2-Code bereits auf main).

## Prüfung dieses Codezustands

- Vollständige Package-Suite: **556 Tests grün** (537 Foundation, 19 Contract), echte temporäre Kopia-Integration.
- Neuer Durchstich: Backup → zusätzliche fremde Identität → Originalquelle entfernen → Katalog/Browser/Suche →
  kompletter Restore → SHA-256-Inhaltsvergleich, leere Datei, Symlink, POSIX-Modus und mtime → Konfliktablehnung →
  Quick-Look-Dateirestore/Cache-Löschung → Abbruch/erneute Admission → Beschreibung/Pin/Unpin mit erhaltenem Safety-Pin.
  Abschließender Secret-Negativscan über reguläre Temp-Dateien; kein Nutzer-Speicherziel/Default-Kopia-Config berührt.
- Regression: Dateirestore mit Unicode-Namen war vor dem Manifestpfad-/NFC-NFD-Fix rot; danach grün.
  Wartebedingung verlangt abgeschlossene Historie und freigegebenen Lauf statt eines kurzfristig leeren Active-Felds.
- Neue Unitfälle: Traversal/Größenlimits, falsche UUID/Symlink-Ziel, private eindeutige Ordner, fremde Selektoren,
  mehrdeutige Namensschreibweisen, Symlink-Abstieg, begrenzte zyklische Suche und Cancellation.
- Xcode Debug `build test`: grün, vier Bundle-/Signaturtests. Format-Lint/Diff sauber, keine Compilerwarnungen.
  Signatur-/Entitlement-/Packaging-Konfiguration unverändert; keine neue Release-Zusage.
- Toolchain wie oben. Codefingerprint `29e46ed920ef…` über 444 Dateien: `/tmp/mackopia-p3-code-state.txt`.
  Finale Logs: `/tmp/mackopia-p3-{swift,xcode,lint}.log`; gezielte Diagnose: `/tmp/mackopia-p3-*-diagnose.log`.
- UI-Checkliste §7.8: Systemkomponenten, sichere Defaults, DE/EN und Preview-Zustände im Code geprüft.
  Keine behaupteten Live-Screenshots, VoiceOver-/Tastatur-/Quick-Look-/Drucknachweise; siehe Ledger.
- Frühere Evidenz: [Phase 2](history/STATUS-Phase2-Abschluss-2026-10-25.md),
  [Phase 1](history/STATUS-Phase1-Abschluss-2026-10-25.md).

## Offene Live-Nachweise und konkrete Grenzen – kein globaler Entwicklungsstopp

| Nachweis | Betroffene Funktion | Exakte nächste Aktion / Besitzer |
|---|---|---|
| Installierter Dienst/XPC | SMAppService, Peer-Vertrauen | Nutzer aktiviert gebaute App/Hintergrunddienst; Agent prüft positive/negative registrierte Peers |
| Login-Keychain/TCC/FDA/Updates | Produktive Secrets/geschützte Quellen | Nutzer + Agent: nur Temp-Ziel, ggf. FDA bestätigen; frische Agent-/Kind-Leseevidenz und Update-ACL prüfen |
| Safari-Testdatei fehlt oder ist >1 MiB | Konservative FDA-Erkennung | Zugriff gesperrt lassen; begrenzte alternative Kind-Leseprobe entwickeln/nachweisen |
| Reales Unmount/Eject/Abziehen | Optionale Hardwarefunktion | Nutzer + Agent: entbehrliches USB-Testvolume, UUID-Wechsel/Veto/Abbruch; kein Force |
| Native Mitteilungen/Aktionen | Benachrichtigungen | Nutzer aktiviert am registrierten Dienst; Agent prüft Zustellung/Retry/Details mit Temp-Plan |
| Integrierter Restore-UI-Durchgang und PDF | Fenster, Quick Look, Recovery-Kit | Agent + Nutzer: Temp-Backup auswählen, Vorschau schließen/Cache prüfen, Restore/Abbruch, Drucklayout und PDF prüfen |
| DE/EN, Light/Dark/Kontrast, Tastatur/VoiceOver | UI-/Releasequalität | Phase 5/6: Screenshots/minimales Fenster und A11y-Audit; bisher nur Code/Previews/Katalog/Build |
| Harte Dienstbeendigung | Quick-Look-Cache | Private Cache-Reste nach Crash möglich; Sitzung beim regulären Schließen/Shutdown bereinigt, Startup-Reinigung ergänzen |
| Große Kataloge/Verzeichnisse | Restore-Browser | >128 Quellen/1.000 Snapshots/8 MiB oder >2.000 Einträge pro Seite blockieren explizit; Pagination vor Freigabe größerer Bestände ergänzen |
| Quarantäne/Gatekeeper/Updates, Kopia-Checkpoint 45 statt 15 Minuten | Release | Phase 6: Installationsartefakt und bewusste Freigabe prüfen; Checkpoint-Produktentscheidung treffen |

## Nächster vollständiger Coding-Auftrag

**Phase 4 aus PROJEKT.md §14: zuerst S3 als vollständigen Backend-Block anschließen.**

Keychain-/Transport- und Erzeugen/Verbinden/Testen-Pfad über Runtime, XPC und Assistent verdrahten;
Offline/Auth/Reconnect und Restore mitführen. Vorhandene Swift-/Spike-Verträge wiederverwenden.
Temporären S3-Lifecycle und Secret-Persistenznegativtest ausführen, dann Package/Xcode/Format und Doku.
Keine fremden Konten/Infrastruktur ohne Auftrag; fehlenden realen Zugang nur als Backend-Nachweis erfassen.
Einstieg: PROJEKT.md §6.2–§6.4, §8–§9, §14 Phase 4 und SPIKE-D-SECRETS.md.
Fertigkriterium: ein S3-Ziel ist im Assistenten sicher eingerichtet, sichert und stellt über denselben Dienst wieder her.
Danach WebDAV-Pipe-Transport, anschließend SFTP inklusive bewusster Host-Key-Freigabe.
Name/Bundle-Präfix MacKopia / com.example.MacKopia; Lizenzmodell offen. [Historienindex](history/README.md).
