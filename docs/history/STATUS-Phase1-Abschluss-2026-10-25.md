# Status & nächster Auftrag

Stand: 2026-10-25. Kompakter Neustarteinstieg; historische Evidenz bleibt im Archiv.
Zuerst AGENTS.md, diesen Status, PROJEKT.md §14 und IMPLEMENTIERUNG.md lesen.

## Aktuelle Produktphase

**Phase 1 ist implementiert und automatisiert integriert; Live-Systemabnahme bleibt offen.**
App → authentifiziertes XPC → alleiniger Hintergrunddienst → bestehende manuelle Kopia-Engine ist verdrahtet.
Der nächste größere Coding-Auftrag ist Phase 2. Fehlende manuelle Freigaben blockieren nur deren Live-Nachweis.

## In progress

| Task | Agent / person | Branch | Modules / files touched | Started |
|---|---|---|---|---|

## Verbindliche Entscheidungen

- macOS 27.x, natives arm64; Xcode 27.1 (27A9275), Swift 6.4 / Sprachmodus 6, SDK 27.
- Kontoloser Ad-hoc-Vertrieb mit Hardened Runtime; keine neuen Entitlements/Abhängigkeiten.
- Agent-Keychain: lokaler Login-Keychain, SecItem, Standard-App-ACL, keine Team-/Access-Group-Pflicht.
  Keine Authentifizierungsdialoge im Hintergrund und kein Datei-Fallback; Update-Stabilität separat prüfen.
- Frische FDA-Evidenz aus Agent UND gebündeltem Kopia. Fehlende Safari-Testdatei blockiert konservativ;
  keine manuell gespeicherte Zugriffsfreigabe. Architekturdetails und Entscheidungen: PROJEKT.md §8–§9, §12, §17.
- Große autonome Funktionsblöcke; Prüfungen bündeln, konkrete Fehler gezielt diagnostizieren.

## Implementiert und verdrahtet

- `LocalBackupService`: Config/History/Keychain/Gate, geschützter Create-/Connect-Lifecycle, manuelle Läufe,
  Stopp/Cleanup/Shutdown, unterbrochene Historie, validierte Planänderungen und explizite Konfigurations-Recovery.
- Volume-UUIDs werden bei Auswahl erfasst und vor Secrets/Bootstrap/Operation erneut geprüft.
  Nichtleere Ziele werden beim Anlegen abgewiesen; unsichere Schreibausgänge löschen keine Ziel-/Secret-Daten.
- XPC Version 2: begrenzte Umschläge vor Domain-Decoding, UUID-Korrelation, Code-Hash-Pinning,
  asynchrone Antwort auf derselben Sitzung, revisionsgebundene Zustände/Progress/Ergebnisse und Reconnect.
- App: Navigation, Einrichtung neuer/vorhandener lokaler Ziele, neuer Plan an bestehendem Ziel,
  Editor für Name/Aktivierung/Quellen/Aufbewahrung, Übersicht, Verlauf, Fehler-/Berechtigungswege, DE/EN, sichere Previews.
- Menüleiste: echter Dienststatus, manueller Start/Stopp und App öffnen; keine unabhängige zweite Engine.
- Gefundener Schedulerfehler behoben: monotone Deadline vor Task-Erzeugung erfassen;
  Queue-Recovery-Test prüft dauerhaften Queue-Abschluss statt vorgelagerter Historienbeobachtung.
- Die übernommenen lokalen Engine-/Plattformänderungen früherer Aufträge bleiben erhalten.
  Branch: `codex/p1-local-workflow`, logische Commits für übernommene Engine, Plattform und lokalen Workflow.
  Aufteilung und offene Integrationsgrenzen: [IMPLEMENTIERUNG.md](IMPLEMENTIERUNG.md).

## Prüfung dieses Codezustands

- Vollständige Package-Suite: **534 Tests grün** (515 Foundation, 19 Contract), echte temporäre Kopia-Integration.
- Neuer Diensttest: Create, Run, bytegleicher Restore, weiterer Plan/Editor, Reopen und Connect;
  Negativprüfungen für Volume-Wechsel, Secret-Persistenz, Safe Mode/Recovery, Grenzen und Cancellation.
- Echter nativer XPC-Test benutzt Produktions-Peer/Envelope an einem ausschließlich testinternen anonymen Endpoint.
  Er ersetzt nicht den registrierten positiven/negativen App-Agent-Peer-Test.
- Xcode Debug `build test`: grün, vier Bundle-/Signaturtests; Format-Lint und Diff-Prüfung sauber.
  Release-Build ebenfalls grün: App/Agent/Kopia mit gültigen Ad-hoc-/Runtime-Signaturen, native arm64;
  eingebetteter Versionspin entspricht der Quelle. Keine neuen Compilerwarnungen.
- Deterministische Timerregression vor Fix rot, danach zwölf gezielte Timer-/History-/Recovery-Tests grün.
  Erster Gesamtlauf fand zwei Automatikrennen; erst der korrigierte finale Gesamtlauf ist obige grüne Evidenz.
- Codefingerprint: `8c2f4b5cd4fd…` über 408 Dateien, `/tmp/mackopia-p1-code-state.txt`; Logs `/tmp/mackopia-p1-{swift,xcode,release,lint}.log`.
  Vorherige Prüfevidenz: [Einstiegsstatus](history/STATUS-Phase1-Einstieg-2026-10-25.md).
- Keine Nutzer-Speicherziele oder Nutzer-Default-Kopia-Konfiguration berührt.

## Offene Live-Nachweise – kein globaler Entwicklungsstopp

| Nachweis | Betroffene Funktion | Exakte nächste Aktion / Besitzer |
|---|---|---|
| Computer Use nicht freigegeben; Live-UI-Versuch scheiterte vor Bedienung | UI-Audit und echte Registrierung | Nutzer: Computer Use erlauben oder selbst gebaute App öffnen; dann Agent prüft den integrierten Pfad |
| SMAppService und positiver/negativer App-Agent-Test | Installierter Dienst/XPC | Nutzer: Release-App nach Programme kopieren, öffnen, „Hintergrunddienst aktivieren“ und ggf. Anmeldeobjekte bestätigen; Agent danach Status/Peer-Prüfung |
| Tatsächlicher Login-Keychain/TCC-Zugriff, Zuordnung und Update-Stabilität | Produktive Secrets/geschützte Quellen | Am registrierten Dienst ein ausschließlich temporäres Ziel anlegen; ggf. nötigen FDA-Eintrag bestätigen, echte Agent-/Kind-Leseevidenz prüfen; Nutzer + Agent |
| DE/EN, Light/Dark/Kontrast, Keyboard, VoiceOver, Hardware/Abziehen | UI-/Releasequalität | Integrierter Audit Phase 5/6; bisher nur sichere Previews, Katalog-/Buildprüfung, keine Screenshot-/A11y-Zusage |
| Safari-Testdatei fehlt oder ist >1 MiB | Konservative FDA-Erkennung | Betroffenen Lauf blockiert lassen; alternative geschützte Kind-Leseprobe mit nachgewiesener Begrenzung ergänzen |
| Quarantäne/Gatekeeper, Updates, Kopia-Checkpoint 45 statt 15 Minuten | Release | Phase 6: Installationsartefakt prüfen und Checkpoint-Produktentscheidung treffen |

## Nächster vollständiger Coding-Auftrag

**Phase 2 aus PROJEKT.md §14: zuverlässiger täglicher Betrieb.**

1. Den vorhandenen `AutomaticBackupRuntime` als einzigen Queue-/Engine-Besitzer in `LocalBackupService`
   übernehmen; gemeinsame Gates, Secrets, Quellprüfung und Shutdown behalten. Keine parallele zweite Runtime.
2. Scheduler/Monitore/Pausen/Retry/Recovery, Health/Plausibilität, Verify/Test-Restore und fällige Wartung
   samt dauerhafter Evidenz verbinden; planbezogenen Fortschritt/Fehler und Menü-/Fenstersteuerung erweitern.
3. Einstellungen/Termine/Pausen persistieren, Fehler mit Folgeaktionen anzeigen; DE/EN und sichere Previews.
4. Ein finaler Prüfblock: virtuelle Uhr/Neustart/Serialisierung/Abbruch, temporärer Gesamtdurchstich,
   Package-Suite, Xcode build/test und Format; Live-Freigaben separat nachweisen.

Fertigkriterium: bestehende Pläne sichern automatisch und nachvollziehbar über denselben Dienstpfad,
Termine/Pausen überleben Neustarts; keine losgelösten Adapter ohne UI-/Runtime-Anbindung.
Einstieg: PROJEKT.md §6.6, §7.3–§7.7, §9, §11.3–§11.4, §12; Implementierungsatlas.
Name/Bundle-Präfix weiterhin MacKopia / com.example.MacKopia; Lizenzmodell offen.
Historie: [alter Status](history/STATUS-2026-10-25.md), [alter Plan](history/PLAN-bis-2026-10-25.md).
