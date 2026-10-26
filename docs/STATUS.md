# Status & nächster Auftrag

Stand: 2026-10-26. Einstieg: AGENTS.md, dieser Status, PROJEKT.md §14 und IMPLEMENTIERUNG.md.
Historische Evidenz bleibt im [Archiv](history/README.md).

## Aktuelle Produktphase

**Phase 4: S3, WebDAV und SFTP vom Assistenten bis Backup/Restore integriert.**
SFTP-Schlüssel-Anmeldung mit bewusster Host-Key-Freigabe und RSA-PEM-Passphrase ist angeschlossen.
Aktueller Branch `main`: S3-/WebDAV-/SFTP-Stand auf ausdrücklichen Nutzerauftrag per Fast-forward übernommen.
Reviewhistorie: [SFTP-PR #6](https://github.com/drhdevorg/mackopia/pull/6),
[WebDAV-PR #5](https://github.com/drhdevorg/mackopia/pull/5).
Keine echte Remote-Infrastruktur angelegt; nur lokale Wegwerf-Fixtures und temporäre Speicherziele verwendet.

## In progress

Keine aktive Implementierungsclaim; Phase-4-Stand auf `main`, nächster Block ist Phase 5.

## Verbindliche Entscheidungen

- macOS 27.x, natives arm64; Xcode 27.1 (27A9275), Swift 6.4 / Sprachmodus 6, SDK 27.
- Ad-hoc-Vertrieb/Hardened Runtime; unveränderte Entitlements/Dependencies/Buildphasen und Kopia 0.23.1.
- Agent besitzt Runtime, Schlüsselbund und Kopia; App nur über authentifiziertes XPC, Version 7.
- Remote-Zugänge als begrenztes Envelope im Keychain-Item. WebDAV/SFTP: Runtime-JSON nur im RAM,
  frische anonyme Pipe pro Prozess, geschütztes Symlink-Verzeichnis, gemeinsame nicht geheime Wartungssperre.
- SFTP: öffentlicher Host-Key aus vertrauenswürdigem Kanal, angezeigten Fingerprint ausdrücklich bestätigen.
  Atomare 0600-known_hosts pro Ziel; vor jeder Operation an Envelope gebunden, Server-Wechsel blockiert.
  Schlüssel-Anmeldung; RSA-PEM im RAM per System-OpenSSL entschlüsselt, normalisierter Schlüssel im Keychain,
  Passphrase verworfen. SSH-Passwort und verschlüsselte OpenSSH-Schlüssel sind noch nicht freigegeben.
- Create-only; Connect erhält fremden Wartungs-Owner. Credential-Ersatz erst nach Status/frischem Format-Blob.
- Neue Pläne manuell bis zur Terminwahl; Mitteilungen aus; Eject nie mit Force.
- Restore nur in neuen privaten UUID-Ordner (0700), Overwrite aus, keine Originalquelle nötig.
- Architektur und Entscheidungen: PROJEKT.md §6.2–§6.4, §8–§9, §11.2, §12 und §17.

## Implementiert und verdrahtet

- Phase 1/2: gemeinsamer Dienst/Queue/Gate, UUID-/FDA-Schutz, Termine/Recovery/Pausen, Health/Nacharbeit.
- Phase 3: Katalog/Browser/Suche, Restore-Fortschritt/Abbruch, Finder/Quick Look/Recovery-Kit ohne Secrets.
- S3/WebDAV: Create/Connect, authentifizierter Credential-Ersatz und gemeinsamer CLI-/Server-/Restore-Pfad.
- `SFTPSetup`/`KopiaSFTPTrust`: begrenzte Eingaben, SHA256-Pin, bestätigte öffentliche Trust-Datei.
- `KopiaSFTPSetup`: Create über Schlüssel-Pipe, Connect über RAM-Konfiguration, Balanced/zstd/Owner;
  RSA-PEM nur im RAM normalisiert. Kein `repository connect`, keine Secret-Datei/Config-Mutation.
- `LocalServiceSFTPSetup`: Keychain-Envelope, gemeinsame Gates/Volume-Schutz, Probe vor Credential-Ersatz,
  Duplikatschutz unabhängig von neuen Schlüsselreferenzen. `RepositoryCredentials` liest frisch für jede Operation.
- `RemoteRepositoryAccess` und alle gemeinsamen CLI-/TLS-/Verify-/Wartungs-/Restore-Adapter verwenden SFTP.
- XPC 7/Agent-Dispatch, Assistent mit mehrzeiliger Schlüsseleingabe/Fingerprint/Freigabe, Credential-Sheet,
  Destination-Liste und Recovery-Kit DE/EN/Previews. Bei Host-/Port-/Key-Änderung Freigabe zurücksetzen.

## Prüfung dieses Codezustands

- Finaler Produktionscode `9437d0d` auf `codex/p4-sftp`, Xcode 27.1 (27A9275), Swift 6.4, arm64.
- Abschließende Package-Vollsuite: **553 Tests / 104 Suites bestanden**, einschließlich echter temporärer
  SFTP-/WebDAV-/S3-/lokaler Integration; keine Compilerwarnungen. Log `/tmp/mackopia-sftp-package-final.log`.
  WebDAV-Lifecycle 160,8 s; SFTP-Lifecycle 21,0 s. Unveränderter Abschlusslauf nach dem unten erfassten Fehler.
- Xcode `build test`: erfolgreich, **4 Bundle-/Signaturtests**, keine Compilerwarnungen;
  bekannte IDE-interne Launch-Diagnostik. Log `/tmp/mackopia-sftp-xcode.log`.
- SFTP gezielt: **4 Tests in 3 Suites bestanden**, echter Dienst-Lifecycle einschließlich PEM-Entschlüsselung,
  falscher Passphrase/Schlüssel/Host-Key, Credential-Erhalt, Create-Duplikat, Backup/Verify/Test-Restore,
  Neustart/Restore ohne Quelle, Connect/fremdem Owner, Offline und Secret-Negativscan.
  Log `/tmp/mackopia-sftp-targeted-final.log`; zusätzliche Duplikat-/XPC-Regressionsfälle im erfolgreichen Vollauf.
- **11 Python-Tests bestanden**; strikter Swift-Format-Lint und `git diff --check` sauber.
- Erster Vollauf: 553 Tests/104 Suites, genau ein Fehler bei automatischer WebDAV-Verifikation;
  alle SFTP-Fälle bestanden. Log `/tmp/mackopia-sftp-package.log`. Unveränderter isolierter WebDAV-Lifecycle
  danach erfolgreich (158,4 s), `/tmp/mackopia-sftp-webdav-diagnosis.log`. Zusätzliche 12×10-Prozent-/1×100-Prozent-
  Prüfungen auf frischem Temp-Ziel bestanden, numerischer Bericht `/tmp/mackopia-verify-sample-report.json`.
  Ursache bisher nicht reproduziert; keine Assertions abgeschwächt, keine automatischen Wiederholungen eingebaut.
- Frühere Fixture-Diagnose: zu langer Unix-Socket-Pfad; eigener kurzer privater ssh-agent-Temp-Ordner behebt das.
- TLS-Fixtures benötigen `MACKOPIA_TEST_PYTHON` auf vorhandenen TLS-1.3-Interpreter (README).
- Frühere Nachweise: [SFTP-Spike/WebDAV-Basis](history/STATUS-Phase4-SFTP-Spike-2026-10-26.md),
  [S3](history/STATUS-Phase4-S3-Abschluss-2026-10-25.md), [Phase 3](history/STATUS-Phase3-Abschluss-2026-10-25.md).

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
| Reales SFTP/SSH/Host-Key | Provider-Kompatibilität | Nutzer stellt entbehrlichen Testordner und öffentlichen Host-Key über vertrauenswürdigen Kanal bereit; Agent prüft Create/Connect/Backup/Restore/Schlüsselwechsel |
| Einmalige WebDAV-Verifikationsablehnung im Vollauf | Prüfevidenz unter paralleler Last | Bei erneutem Auftreten sanitisierte Prozess-/Prüfzähler und Fixture-Zustand erfassen; erster Fehler und isolierte erfolgreiche Diagnose oben |

## Nächster vollständiger Coding-Auftrag

**Phase 5: integrierte macOS-Bedienung und Betriebsqualität prüfen und vervollständigen.**

Einstieg: PROJEKT.md §4–§5, §11–§14 Phase 5, AGENTS.md §7 und IMPLEMENTIERUNG.md.
Fenster/Menüleiste/Shortcuts/Fehleraktionen und Remote-Assistenten im zusammenhängenden Temp-Workflow prüfen;
Startup-Cleanup für verwaiste private Quick-Look-Caches ergänzen. DE/EN, Light/Dark/Kontrast, minimales Fenster,
Tastatur und VoiceOver samt Screenshots erfassen; mit Instruments Idle-CPU/Speicher/I/O/Fortschrittsfrequenz messen.
Befunde mit Regressionstests beheben, keine spekulativen Frameworks/Entitlements. Nicht mögliche manuelle
Systemaktionen konkret im Ledger führen. Fertig: belegter integrierter Audit, behobene Codebefunde,
relevante Package-/Xcode-/Format-Prüfung und kompakte Übergabe. Reale Provider-/Hardware-Checks bleiben separat.
Name/Bundle-Präfix MacKopia / com.example.MacKopia; Lizenzmodell offen.
