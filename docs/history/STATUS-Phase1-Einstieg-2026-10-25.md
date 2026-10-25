# Status & nächster Auftrag

Stand: 2026-10-25. Neustarteinstieg, keine wachsende Sessionchronik (Ziel ≤120 Zeilen).
Zuerst AGENTS.md, diesen Status, PROJEKT.md §14 und IMPLEMENTIERUNG.md lesen;
danach nur die zum Auftrag gehörenden Spezifikationsabschnitte und Quelldateien.

## Aktuelle Produktphase

**Phase 1: Nutzbarer lokaler Backup-Workflow.** Die frühere Phase-0-Abnahmesperre ist aufgehoben.
Bewährte Package-Engine wiederverwenden; jetzt Dienstbesitz, Secrets, XPC und UI vertikal verbinden.
Der Nutzerauftrag dieser Sitzung ist die Neuplanung samt Plattform-/Workflow-Umstellung,
nicht die bereits als fertig behauptete Umsetzung des gesamten lokalen Workflows.

## In progress

| Task | Agent / person | Branch | Modules / files touched | Started |
|---|---|---|---|---|
| Phase 1: lokaler App–XPC–Dienst–Backup-Workflow | Codex | codex/p1-local-workflow | Secrets, AgentProtocol, BackupEngine, App, Agent, Tests, docs | 2026-10-25 |

## Verbindliche Entscheidungen

- Nur macOS 27.x / Apple Silicon / natives arm64, keine Alt-OS-/Intel-/Rosetta-Pfade.
- Neueste stabile Xcode-/Swift-/SwiftUI-Toolchain; aktuell lokal Xcode 27.1 (27A9275), Swift 6.4, SDK 27.
  Swift-Sprachmodus 6; keine automatische Beta-/RC-Umstellung.
- Vertrieb außerhalb des App Store ohne Apple-Konto, Developer ID oder Pflicht-Notarisierung.
  Lokale Ad-hoc-Signaturen plus tatsächliche Hardened Runtime; bewusste Gatekeeper-Freigabe vorgesehen.
- Große integrierte Aufträge autonom abschließen; Tests an Block-/Phasengrenzen bündeln.
  Gezielte Compiler-/Sicherheits-/Regressionsdiagnosen innerhalb des Blocks ausdrücklich vom Nutzer erlaubt;
  Sicherheitsinvarianten niemals zugunsten der Tokenzahl umgehen.
- Kein neuer Chat nach jeder Teilaufgabe; Kontext über kompakte Dateien und gezieltes Lesen erneuern.

## Implementierter Stand

- Isolierter Kopia-Prozess/Server mit TLS-Pinning, Policies, Domain/Config/History, Preflight und Schutz.
- Manueller Dateisystem-Backup-Durchstich; automatische Package-Runtime mit Scheduler/Monitoren,
  persistenten Pausen/Recovery/Reload, Health/Plausibilität, Verify und monatlichem Test-Restore.
- Geschützte fällige Full-Wartung vorhanden; automatische Anbindung und dauerhafte Wartungsevidenz fehlen.
- XPC-Ping/Registrierungsgrenze mit Bundle-/Code-Hash-Vertrauen ohne Team-ID vorhanden.
- App-/Menüleisten-UI sind Platzhalter; vollständige produktive Agent-/XPC-Komposition fehlt.
- Modul-/Dateieinstiege und Integrationsgrenzen: [IMPLEMENTIERUNG.md](../IMPLEMENTIERUNG.md).
- Arbeitsbaum enthält erhaltene lokale Batch-4-/XPC-Änderungen früherer Aufträge; nichts verwerfen.
  Neuer Branch `codex/p1-macos27-plan`; kein Commit/Push/PR dieser Umstellung.

## Nächster vollständiger Coding-Auftrag

**Phase 1 aus PROJEKT.md §14 als zusammenhängenden lokalen Workflow implementieren.**

1. Kontolosen, ausschließlich agentverwalteten Keychain-Pfad ergänzen und in die Dienstkomposition übernehmen.
2. Einen Runtime-Besitzer und validierte Konfigurations-/Setup-/Laufsteuerungs-/Status-XPC-Verträge verbinden.
3. AgentConnection, Navigation, lokale Einrichtung, Planeditor, Übersicht und echte Steuerung DE/EN verdrahten.
4. Fehler-/Offline-/Berechtigungs-/Reconnect-/Abbruchzustände fertigstellen; sichere Previews vorhalten.
5. Eine gebündelte relevante Prüfrunde und kompakte Übergabe; interne Teilschritte ohne neues `continue` fortsetzen.

Fertigkriterium: lokaler Nutzerworkflow bis Backup-Ergebnis funktioniert über den echten Dienstpfad,
oder nur konkret benannte, externe Freigaben verhindern dessen reale Ausführung; unabhängige Teile fertigstellen.
Einstieg: PROJEKT.md §5–§6, §7.1/§7.3–§7.5, §8–§9, §11–§12 und Implementierungsatlas.

## Offene Nachweise – kein globaler Entwicklungsstopp

| Nachweis / Problem | Betroffene Funktion | Nächste konkrete Aktion / Besitzer |
|---|---|---|
| Keychain bisher Team-/Access-Group-basiert | Produktive Secret-Speicherung | Coding-Auftrag Phase 1: Agent-Keychain ohne Team-ID; kein Datei-Fallback |
| SMAppService / echter positiver und negativer App-Agent-Peer-Test | Produktiver Hintergrunddienst/XPC | Nach Komposition Ad-hoc-Build installieren/registrieren und echte Verbindung prüfen; Agent, notwendige Systemzustimmung Nutzer |
| TCC/FDA und Kopia-Kindprozesszuordnung | Lesen geschützter Quellen | Integrierten Dienst prüfen; benötigten FDA-Eintrag eindeutig ermitteln, fehlende Zustimmung Nutzer |
| Quarantänisierter Download, Gatekeeper, Update-/Keychain-/FDA-Stabilität | Installierbarer Release | Phase 6 mit fertigem Artefakt; keine Apple-ID-Anforderung |
| A11y, Light/Dark/Kontrast, Tastatur, Hardware/Abziehen, Performance | UI- und Releasequalität | Gebündelter Audit Phase 5/6; offene manuelle Nachweise ehrlich ausweisen |
| Kopia-Checkpoint 45 statt 15 Minuten | Checkpoint-Anforderung | Vor Release tatsächliches Verhalten dokumentieren und Produktentscheidung treffen; kein Alt-Phasenstopp |

## Letzte Prüfung und Änderungen dieser Sitzung

- Finaler Codezustand auf `codex/p1-macos27-plan`, uncommittet: SHA256 `d96d97c84665…`
  über 389 versionierte/nicht ignorierte Code-/Config-/Testdateien; Doku ausgeschlossen.
  Voller Fingerprint: `/tmp/mackopia-macos27-code-state.txt`; Xcode 27.1 / Swift 6.4 / SDK 27.
- Ein finaler Prüfblock: 521 Swift-Tests (502 Foundation, 19 Contract) inklusive echter temporärer
  Kopia-Integration, 43 Python-Tests, Xcode Debug build/test mit vier Artefakttests und sauberer Release-Build grün.
  Python-Loopback-Test zunächst durch Sandbox verweigert, mit Socket-Zugriff unverändert erfolgreich.
- Release-App/Agent/Kopia: nur arm64, gültige verschachtelte Ad-hoc-/Runtime-Signaturen, keine Entitlements;
  App und Agent verlangen nachweislich macOS 27.0. Keine neuen Compilerwarnungen, Format-Lint sauber.
- Native ARM-Fetch-Prüfung, PBX-/Workflow-YAML-Syntax, aktuelle lokale Markdown-Links und Diff-Prüfung sauber.
  Logs: `/tmp/mackopia-macos27-{python,fetch,swift,xcode,release,lint}.log`.
- Umgestellt: aktuelle Toolchain/Plattform, nativer Fetch, CI-Runner und Prüftakt, gemeinsame Regeln,
  sechs Produktphasen, 77-zeiliger Implementierungsatlas; alte Status-/Planhistorie unverändert archiviert.
- Nicht geprüft: Remote-CI-Ausführung, echte neue Installation/Registrierung/FDA/Keychain und manueller UI-Audit.
  Keine Nutzer-Speicherziele berührt, keine Abhängigkeiten/Entitlements ergänzt.

## Offene Produktfragen und Schutz vor Verwechslung

- Name/Bundle-Präfix vorerst `MacKopia` / `com.example.MacKopia`; Lizenzmodell noch offen.
- Niemals Nutzer-Default-Kopia-Konfiguration oder `/Volumes/TRESOR` berühren; nur temporäre Testziele.
- Lange Vorgeschichte und alte Testergebnisse: [Statusarchiv](STATUS-2026-10-25.md).
  Alte Phasen-/Batch-Nummern: [Planarchiv](PLAN-bis-2026-10-25.md), kein aktiver Auftrag.
