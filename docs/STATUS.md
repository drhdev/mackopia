# Status & nächster Auftrag

Stand: 2026-10-26. Neustarteinstieg: AGENTS.md, dieser Status, PROJEKT.md §14 und IMPLEMENTIERUNG.md.
Historische Evidenz bleibt im [Archiv](history/README.md).

## Aktuelle Produktphase

**Phase 4: WebDAV vom Assistenten bis Backup/Restore integriert und automatisiert geprüft.**
Phase 1–3 und S3 bleiben integriert. Nächster Backend-Block nach WebDAV: SFTP.
Branch `codex/p4-webdav`, Basis `codex/p4-s3`; [Draft-PR #5](https://github.com/drhdevorg/mackopia/pull/5).
Beide Branches gepusht; keine echte Remote-Backup-Infrastruktur angelegt.

## In progress

| Task | Agent / person | Branch | Modules / files touched | Started |
|---|---|---|---|---|
| — | — | — | — | — |

## Verbindliche Entscheidungen

- macOS 27.x, natives arm64; Xcode 27.1 (27A9275), Swift 6.4 / Sprachmodus 6, SDK 27.
- Ad-hoc-Vertrieb mit Hardened Runtime; keine neuen Entitlements/Abhängigkeiten/Buildphasen.
- Agent besitzt Runtime, Schlüsselbund und Kopia; App ausschließlich über authentifiziertes XPC, Version 6.
- Remote-Zugänge als begrenztes Envelope im bestehenden Keychain-Item. S3 ohne Credential-Felder in Connection;
  WebDAV ohne reguläre Connection, Runtime-JSON nur im Speicher über frische anonyme Pipe pro Prozess.
- WebDAV: geschütztes 0500-Symlink-Verzeichnis, gemeinsame 0600-Wartungssperre; keine Config-Mutation.
  Create-only, explizite Cache-Kapazitäten, Balanced/zstd und Owner; Connect erhält fremden Owner.
- HTTPS; HTTP ausschließlich für literales 127.0.0.1 im lokalen Test. Kein Credential-Ersatz ohne Status und
  frischen Format-Blob-Read. Kopias WebDAV-Auth-Retries können bis zum 60-Sekunden-Probelimit dauern.
- Neue Pläne manuell bis zur Terminwahl; Mitteilungen aus; Eject nie mit Force.
- Restore nur in neuen privaten UUID-Ordner (0700), Overwrite aus, keine Originalquelle nötig.
- Recovery-Kit im nativen Druck-/PDF-Dialog ohne Secrets; Quick Look ≤50 MB, privater Sitzungscache.
- Architektur/Entscheidungen: PROJEKT.md §6.2–§6.4, §8–§9, §11.2, §12 und §17.

## Implementiert und verdrahtet

- Phase 1/2: gemeinsamer Dienst/Queue/Gate, UUID-/FDA-Schutz, Scheduling/Recovery/Pausen, Health und Nacharbeit.
- Phase 3: Katalog/Browser/Suche, Restore-Task/Fortschritt/Abbruch, Finder/Quick Look/Kit; Reservierung bis Reaping.
- S3: Create/Connect, authentifizierter Credential-Ersatz, gemeinsame CLI-/Server-/Restore-Adapter; Nachweise im Archiv.
- `WebDAVSetup`/`RepositoryCredentials`: validiertes reflektionsgeschütztes Keychain-Envelope, frische Auflösung.
- `KopiaWebDAVSetup`: Create-only mit Environment, Connect via Status/Format und Owner; vollständiges JSON nur im RAM.
- Gemeinsame CLI-Adapter und `KopiaBackupSession` verwenden den bestehenden nativen Pipe-Transport pro Spawn;
  stdin bleibt für Shutdown frei. `RemoteRepositoryAccess` prüft S3 und WebDAV, kein lokales Binding für WebDAV.
- Dienst/XPC 6/Agent-Dispatch, Assistent mit HTTPS-URL und sicheren Zugangsfeldern, Credential-Sheet, DE/EN/Previews.
  Recovery-Kit enthält URL und Hinweis zum sicheren Pipe-Verfahren ohne Credentials.
- Keine Originalquellen-/Volume-Überwachung beim Remote-Browse; Ausgabe/Backup-Quellen bleiben UUID-geschützt.

## Prüfung dieses Codezustands

- Finaler Swift-Codezustand auf `codex/p4-webdav`, Xcode 27.1 (27A9275), Swift 6.4, arm64.
- Package: **550 Tests / 102 Suites bestanden**, einschließlich echtem WebDAV-Lifecycle (164,9 s),
  S3-/lokalem Backup und Restore; keine Compilerwarnungen. Log `/tmp/mackopia-webdav-package-tls.log`.
- Xcode `build test`: **erfolgreich, 4 Bundle-/Signaturtests bestanden**, keine Compilerwarnungen;
  Xcode meldet eine IDE-interne Launch-Diagnostik. Log `/tmp/mackopia-webdav-xcode.log`.
- Strikter Format-Lint und `git diff --check` sauber. Keine Änderung an Kopia-Pin, Entitlements oder Dependencies.
- WebDAV: Grenzen/Envelope/Pipe, Create-Duplikat ohne Formatänderung, Backup/Verify/Test-Restore,
  Neustart/Restore ohne Quelle, Credential-Erhalt, Connect mit fremdem Owner, Offline und Secret-Negativscan.
- Timeout zählt als Ablehnung, Cancellation bleibt Abbruch; Regression vorhanden.
- Testumgebung: `MACKOPIA_TEST_PYTHON` auf TLS-1.3-Interpreter setzen; Startup-Check und Anleitung in README.
  Erster Lauf mit Apples LibreSSL-Python scheiterte an TLS-Fixtures und wurde beendet; korrigierter Vollauf bestand.
- Frühere Evidenz: [S3](history/STATUS-Phase4-S3-Abschluss-2026-10-25.md),
  [Phase 3](history/STATUS-Phase3-Abschluss-2026-10-25.md), [Phase 2](history/STATUS-Phase2-Abschluss-2026-10-25.md).

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
| Harte Dienstbeendigung | Quick-Look-Cache | Private Cache-Reste möglich; Startup-Reinigung ergänzen, regulärer Close/Shutdown bereinigt |
| Große Kataloge/Verzeichnisse | Restore-Browser | >128 Quellen/1.000 Snapshots/8 MiB bzw. >2.000 Einträge blockieren; Pagination vor größerer Freigabe |
| Gatekeeper/Updates, Checkpoint 45 statt 15 Minuten | Release | Phase 6: Installationsartefakt prüfen; Checkpoint-Produktentscheidung treffen |

## Nächster vollständiger Coding-Auftrag

**Phase 4: SFTP als vollständigen Backend-Block anschließen.**

SFTP: bewusste Host-Key-Freigabe, sichere Schlüssel-/Passphrase-Zuführung zuerst gegen gepinntes Kopia belegen;
keine Secret-Datei-Ausnahme, kein ungeprüftes Passwort-Environment, keine neuen Abhängigkeiten ohne Freigabe.
Danach Keychain, Create/Connect/Testen, Runtime, XPC, Assistent, Offline/Auth/Reconnect und Restore verbinden.
Einstieg: PROJEKT.md §6.2–§6.4, §8–§9, §14 Phase 4, SPIKE-D-SECRETS.md und WebDAV/S3-Komposition.
Fertig: SFTP über denselben Dienst einrichten/sichern/wiederherstellen, Host-Key-Wechsel blockiert;
echter temporärer Lifecycle/Secret-Negativscan, Package/Xcode/Format/Doku.
Name/Bundle-Präfix MacKopia / com.example.MacKopia; Lizenzmodell offen.
