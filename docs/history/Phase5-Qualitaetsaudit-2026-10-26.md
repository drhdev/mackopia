# Phase 5 – Qualitätsaudit, 2026-10-26

## Umfang und Codezustand

Branch `codex/p5-native-quality`, Produktionscode `70309cb`, [Draft PR #7](https://github.com/drhdevorg/mackopia/pull/7). Basis: integrierter Phase-4-Stand auf `main`.
Xcode 27.1 (27A9275), Swift 6.4, Sprachmodus 6, SDK macOS 27, natives arm64.
Kopia 0.23.1, unveränderte Dependencies/Entitlements/Buildphasen/XPC-Version 7.
Dies ist ein automatisierter und statischer Audit mit konkretem Live-Blocker, keine abgeschlossene UI-Abnahme.

## Befunde und verdrahtete Korrekturen

| Befund | Änderung | Evidenz |
|---|---|---|
| Private Vorschau bleibt nach hartem Dienstabbruch liegen | `RestorePreviewCache` räumt beim Dienststart und vor neuer Vorschau eigene UUID-Sitzungen auf | 3 Cache-Tests plus Dienst-Neustarttest, vorhandener echter Restore-/Vorschau-Lifecycle |
| Restore fehlt als laufender Vorgang in der Menüleiste | Laufendes Symbol, Restore-Text, Fortschrittsanzeige und Abbrechen über vorhandenen Dienstvertrag | Xcode-Build; Live-Menüleistenprüfung offen |
| Health-Warnung oder nicht verfügbarer Dienst fehlt im Menüleistensymbol | Warnungszustand berücksichtigt jede nicht-OK-Health und `unavailable` | Statischer Zustandsvergleich; Live-Prüfung offen |
| ⌘. bleibt während Request aktiv, während Toolbar Stoppen sperrt | Derselbe Busy-Guard für Menükommando und Toolbar | Statischer Abgleich; Tastaturdurchgang offen |
| Fortschritt/Pausenmenü/Quellenentfernen ohne expliziten A11y-Namen | Bestehende DE/EN-Texte als Labels ergänzt, Backup-Fortschritt in Menüleiste bestimmt falls verfügbar | Build/Format/Katalogprüfung; VoiceOver offen |
| README beschreibt SFTP noch als nächsten Backend-Schritt | Integrierten Backend-Stand korrigiert | Dokumentprüfung |

## Cache-Sicherheitsvertrag

Nur der Agent besitzt den Cache. Cleanup greift ausschließlich auf
`Library/Caches/MacKopia/QuickLook` unter dem injizierten Home zu. Der Root muss symlinkfrei,
regulär, im Besitz des aktuellen Nutzers und 0700 sein. Nur kanonische UUID-Namen mit demselben
Besitzer/Modus und regulärem Verzeichnistyp werden entfernt. Unbekannte Namen und Symlinks
werden nicht entfernt; Symlink-Ziele innerhalb der Sitzung bleiben beim rekursiven Löschen erhalten.
Ein fehlender Root erzeugt beim Startup keine Verzeichnisse. Ein wiederholtes `start()` bereinigt
keine laufende Sitzung. Startup-Fehler landen ohne Pfade im Logger; vor neuer Vorschau wird die
Prüfung wiederholt und bei Fehlern abgewiesen. Andere Backups werden dadurch nicht gesperrt.
Der Test verwendet ausschließlich temporäre Homes, keine Nutzerdaten und keinen produktiven Cache.

## Automatisierte Prüfung

- Package: **557 Tests / 105 Suites bestanden**, einschließlich realer temporärer lokaler/S3-/WebDAV-/SFTP-
  und Restore-Integration; `/tmp/mackopia-p5-package.log`, Laufzeit 164,4 s.
- Cache: Schutz privater Sitzungen, Symlinks innerhalb/außerhalb der Sitzung, unbekannter Dateien,
  nicht privatem/umgeleitetem Root, fehlendem Root, Idempotenz und Dienststart geprüft.
- Strikter Swift-Format-Lint sauber; Diff-Whitespace sauber.
- Kataloge: App 246 / Agent 126 Einträge, kein nichtleerer Schlüssel ohne Englisch.
- Xcode `build test`: **Exit 65**, Test-Runner hängt vor Verbindungsaufbau (832 s), zusätzlich
  Daemon-Control-Session-Timeout. Log `/tmp/mackopia-p5-xcode.log`. Keine Swift-Compilerwarnungen.
  Gezielte Diagnose per `xcrun xctest` auf gebautem Bundle: **4 Tests bestanden**, 0,063 s;
  `/tmp/mackopia-p5-bundle-direct.log`. Das ersetzt keinen erfolgreichen kombinierten Xcode-Lauf.
  Eigenständiger Xcode-Build **erfolgreich**, `/tmp/mackopia-p5-build.log`.
  Nach bestätigtem Entsperren `test-without-building` erneut ohne Testergebnis im IDE-Start;
  bewusst abgebrochen, `/tmp/mackopia-p5-xcode-unlocked.log`. Keine weitere Vollsuite wiederholt.
- Erster Compile-Versuch fand einen fehlenden `BackupDomain`-Import im neuen Helper; vor der
  erfolgreichen Package-Vollprüfung korrigiert. Keine Assertions oder Sicherheitsregeln abgeschwächt.

## Live-Audit und exakter Wiederaufnahmeweg

Computer Use inventarisierte native Oberflächen erfolgreich. Der Versuch, das frisch gebaute
`MacKopia.app` zu öffnen, meldete: Mac gesperrt, automatisches Entsperren nicht möglich.
Der Nutzer hat auf Nachfrage „entsperrt“ bestätigt. Anschließend liefen native `getApp`-Aufrufe
für das gebaute MacKopia nach 30 und 60 Sekunden in Timeout/Kernel-Reset; auch `getApp` für den
bereits laufenden Finder scheiterte nach 47 Sekunden. `getState` liefert weiterhin das App-Inventar.
Damit bleibt der native Automationszugriff blockiert; ein MacKopia-Startfehler ist daraus nicht belegt.
Keine Screenshots, UI-/VoiceOver-Abnahme, Dienstregistrierung oder Instruments-Messwerte ableiten.
`xcrun xctrace list templates` funktioniert nach Cache-Freigabe; eine Template-Liste ist kein Profil.

Nach Wiederherstellung der nativen Computer-Use-Verbindung, Besitzer Agent + Nutzer:

1. Finder-AX-Zugriff nachweisen, dann gebautes App-Bundle öffnen. Ohne Dienst: klare Offline-Aktion, ⌘N/⌘B/⌘. gesperrt;
   ⌘, öffnet native Einstellungen, ⌘R führt nach Verbindung in Restore. Keine automatische Registrierung.
2. Registrierten Dienst und Keychain/FDA erst mit den nötigen bewussten Systemfreigaben aktivieren.
   Nur neue lokale Temp-Quelle/Temp-Speicherziel verwenden, nie bestehende Nutzerziele.
3. Neuer Plan → Backup → Prüfen → Restore → Quick Look schließen. Menüleistenstatus,
   Backup-/Restore-Abbruch und Fehler-/Wiederholungsaktion mit demselben Zustand vergleichen.
4. S3/WebDAV/SFTP-Assistenten samt Credential-Sheet, Host-Key-Freigabe und Fehlereingaben ansehen;
   nur lokale Wegwerf-Fixtures verwenden. Echte Provider bleiben im separaten Ledger.
5. DE und EN, Light/Dark/Increase Contrast bei minimalem Fenster: Screenshots pro relevante Ansicht;
   keine abgeschnittenen Aktionsbuttons. Tastatur-only, VoiceOver, Reduce Motion/Transparency prüfen.
6. Instruments Activity Monitor/File Activity/Time Profiler: nach Beruhigung 60 s Idle, danach Backup/
   Restore mit Fortschritt. CPU/Speicher/I/O und Updatefrequenz (≤ etwa 4 Hz) dokumentieren.
   Keine Zahlen aus Builds, Tests oder einem gesperrten Desktop als Produktmessung ausgeben.

Weitere bekannte Bedienlücken zur integrierten Prüfung: Quellen-Drag-and-drop, Entfernen per Entf/Undo,
Menüleisten-Restore-Navigation und Fehleraktionen sowie Quellen-/Snapshot-Pagination. Bestehende Grenzen
werden bis zur Implementierung weiter angezeigt; diese Korrekturen behaupten keine vollständige Phase 5.
