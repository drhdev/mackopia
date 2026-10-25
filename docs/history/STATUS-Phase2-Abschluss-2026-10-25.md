# Status & nächster Auftrag

Stand: 2026-10-25. Kompakter Neustarteinstieg; historische Evidenz bleibt im Archiv.
Zuerst AGENTS.md, diesen Status, PROJEKT.md §14 und IMPLEMENTIERUNG.md lesen.

## Aktuelle Produktphase

**Phase 2 ist im lokalen Dienst integriert und automatisiert geprüft; Live-Systemabnahme bleibt offen.**
Manuelle und automatische Backups gehören derselben Runtime. Termine, Pausen, Recovery und
Prüfnachweise sind im Fenster und der Menüleiste angebunden. Nächster Coding-Auftrag: Phase 3.

## In progress

| Task | Agent / person | Branch | Modules / files touched | Started |
|---|---|---|---|---|

## Verbindliche Entscheidungen

- macOS 27.x, natives arm64; Xcode 27.1 (27A9275), Swift 6.4 / Sprachmodus 6, SDK 27.
- Kontoloser Ad-hoc-Vertrieb mit Hardened Runtime; keine neuen Entitlements/Abhängigkeiten/Buildphasen.
- Keychain ausschließlich im Agent, Standard-App-ACL, keine Team-/Access-Group-Pflicht, kein Dialog im Hintergrund.
- FDA verlangt frische Agent- UND Kopia-Leseevidenz; fehlende Safari-Testdatei blockiert konservativ.
- Neue Pläne bleiben bis zur bewussten Terminwahl manuell. Komplexe bestehende Termine bleiben erhalten.
- Mitteilungen explizit aktivierbar, Standard aus; erster Erfolg einmal, Probleme höchstens einmal je Plan/24 Stunden.
- Auswerfen ausschließlich abnehmbare lokale UUID-gebundene Volumes, reguläre DiskArbitration-Optionen, kein Force.
- Architektur und Entscheidungen: PROJEKT.md §6.6–§7.7, §8–§9, §11–§12, §17.

## Implementiert und verdrahtet

- `LocalBackupService` besitzt genau eine `AutomaticBackupRuntime` mit Queue/Runner/Engine, Zeit-/Ereignis-
  Scheduler, nativen Monitoren, Retry, persistenten Pausen und Queue-/Historien-Recovery.
- Setup/Editor sperren Admissions und Entnahme vor suspendierenden Mutationen. Aktive Backups ergeben `busy`.
  Steuer-UUID-Sperren halten Folgeläufe während Stop-/Pause-/Prüf-Cleanup; Schedulerrevisionen verlieren keine Freigabe.
- Gemeinsame Gates, Keychain, Volume-UUID-/FDA-Prüfung, SleepAssertion und Cancellation/Shutdown bleiben erhalten.
- Serielle Nacharbeit: fällige 1-/10-Prozent-Verify-Stufen, Test-Restore, frische Owner-/Terminprüfung und fällige
  Full-Wartung; append-only Ziel-Wartungsevidenz. Explizites Verify benutzt denselben Drain.
- `PlanRuntimeState`: nächste Termine, Plan-/globale Pause, Health, getrennte Verify-/Restore-/Wartungsnachweise
  und feste planbezogene Fehler. Restore-Fehler kritisch, Wartungsfehler warnend; keine Rohdiagnosen/Secrets.
- XPC Version 3: Pause/Fortsetzen/Verify/Mitteilungen/Automatik-Neustart; Grenzen/Korrelation/Code-Hash-Pinning bleiben.
  Expliziter Automatik-Neustart joint den alten Besitzer und startet eine frische Beobachtung.
- Editor: manuell/Intervall/täglich/Mount, Nachholen/Netzteil, optionales Auswerfen. Fenster: Health/Folgeaktionen,
  Prüfen, Pause/Fortsetzen. Menüleiste: Status, letzter Erfolg, Laufsteuerung und globale Pause. DE/EN, sichere Previews.
- Agent-Mitteilungen mit getesteter Entscheidungslogik; Berechtigungsdialog nur nach expliziter Aktivierung,
  UUID-/Datumsledger ohne Secrets, Retry/Details-Aktionen. Previews initialisieren keine reale Mitteilungsanbindung.
- Branch: `codex/p2-daily-operation`, basiert auf `codex/p1-local-workflow` (offener Vorgänger-PR #2).

## Prüfung dieses Codezustands

- Vollständige Package-Suite: **550 Tests grün** (531 Foundation, 19 Contract), echte temporäre Kopia-Integration.
- Gesamtdurchstich: Create → manueller Lauf → monatliche 10-Prozent-Prüfung/Test-Restore → gespeicherter
  Intervalltermin/virtuelle Zeit → automatischer Lauf → explizites Verify → bytegleicher Restore → Reopen/Connect.
  Secret-Negativscan, Pausen/Optionen/Fehler über Neustart, Monitor-Ausfall/Neustart, Volume-Mountpoint-Auflösung und Eject-Ablehnung geprüft.
- Stop-/Pause-Regressionsfälle waren vor dem Queue-Steuersperrenfix rot. Ein weiterer Test wartete zuerst nur auf
  Historienbeginn; korrigiert auf Queue-/Laufabschluss. Mountpoint-Regression vor dem Fix ebenfalls rot.
  Nur der finale Gesamtlauf gilt als grüne Evidenz.
- Xcode Debug `build test`: grün, vier Bundle-/Signaturtests. Format-Lint und Diff-Prüfung sauber;
  keine Compilerwarnungen. Signatur-/Entitlement-/Packaging-Konfiguration unverändert; keine neue Release-Zusage.
- Toolchain wie oben; Codefingerprint `69706db7ba30…` über 427 Dateien: `/tmp/mackopia-p2-code-state.txt`.
  Logs: `/tmp/mackopia-p2-{swift,xcode,lint}.log`. Gezielte Diagnose: `/tmp/mackopia-p2-*-diagnose*.log`.
- Kein Nutzer-Speicherziel und keine Nutzer-Default-Kopia-Konfiguration berührt. Eject-Negativtests werfen nichts aus.
- Frühere Phase-1-/Release-Evidenz: [Phase-1-Abschluss](history/STATUS-Phase1-Abschluss-2026-10-25.md).

## Offene Live-Nachweise – kein globaler Entwicklungsstopp

| Nachweis | Betroffene Funktion | Exakte nächste Aktion / Besitzer |
|---|---|---|
| Computer Use bisher nicht freigegeben | Live-UI/Registrierung | Nutzer erlaubt Computer Use oder öffnet die gebaute App; Agent prüft danach den integrierten Pfad |
| SMAppService und registrierter positiver/negativer App-Agent-Test | Installierter Dienst/XPC | Nutzer installiert/öffnet App und aktiviert Hintergrunddienst; Agent prüft Status/Peer |
| Login-Keychain/TCC/FDA und Update-Stabilität | Produktive Secrets/geschützte Quellen | Nutzer + Agent: ausschließlich Temp-Ziel am registrierten Dienst; ggf. FDA bestätigen, Agent-/Kind-Leseevidenz prüfen |
| Safari-Testdatei fehlt oder ist >1 MiB | Konservative FDA-Erkennung | Betroffenen Zugriff gesperrt lassen; begrenzte alternative Kind-Leseprobe implementieren/nachweisen |
| Reales Unmount/Eject und Abziehen | Optionales Auswerfen/Hardware | Nutzer + Agent: entbehrliches USB-Testvolume, UUID-Wechsel/Veto/Cancellation/Abziehen gezielt prüfen; kein Force |
| Native Mitteilungszustellung und Aktionen | Benachrichtigungen | Nutzer aktiviert Einstellung am registrierten Dienst; Agent prüft Zustellung/Retry/Details mit Temp-Plan |
| DE/EN, Light/Dark/Kontrast, Tastatur, VoiceOver | UI-/Releasequalität | Phase 5/6: Screenshots und integrierter A11y-Audit; bisher Previews/Katalog/Build, keine manuelle Zusage |
| Quarantäne/Gatekeeper, Updates, Kopia-Checkpoint 45 statt 15 Minuten | Release | Phase 6: Installationsartefakt und bewusste Freigabe prüfen; Checkpoint-Produktentscheidung treffen |

## Nächster vollständiger Coding-Auftrag

**Phase 3 aus PROJEKT.md §14: vollständige Wiederherstellung und Recovery.**

1. Snapshot-Tabelle/Filter und lazy Browser/Suche über AgentProtocol/XPC und den alleinigen Dienstbesitzer verbinden.
2. Datei/Ordner/Snapshot-Auswahl, Zielauswahl, Fortschritt/Abbruch und sichere Konfliktregeln ohne stilles Überschreiben.
3. Quick Look und Recovery-Kit/Hilfe verbinden; fremde Quellidentitäten und bekannte Metadatenlimits berücksichtigen.
4. Repräsentative Temp-Daten/Metadaten, Hashvergleich, Konflikt/Abbruch; final Package/Xcode/Format und Doku.

Fertigkriterium: Ein Backup ist in der App auffindbar, prüfbar und sicher wiederherstellbar; gemeinsame Gates,
Secrets-/Quell-/Ziel-UUID-Grenzen bleiben erhalten. Einstieg: PROJEKT.md §6.4, §8.4, §9, §11.2, §12.
UI-Verfeinerungen (Wochentageditor, weitere Mitteilungsvarianten/Stoppen-und-Auswerfen) gehören zum Phase-5-Audit.
Name/Bundle-Präfix MacKopia / com.example.MacKopia; Lizenzmodell offen. [Historienindex](history/README.md).
