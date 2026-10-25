# Status & nächster Auftrag

Stand: 2026-10-25. Neustarteinstieg: AGENTS.md, dieser Status, PROJEKT.md §14 und IMPLEMENTIERUNG.md.
Historische Evidenz bleibt im [Archiv](history/README.md).

## Aktuelle Produktphase

**Phase 4: S3 vom Assistenten bis Backup/Restore integriert und automatisiert geprüft.**
Phase 1–3 bleiben integriert. Nächster vollständiger Backend-Block nach der S3-Abnahme: WebDAV.
Lokaler Branch `codex/p4-s3`, Basis `main`; kein Push, kein PR, keine echte Cloud-Infrastruktur angelegt.

## In progress

| Task | Agent / person | Branch | Modules / files touched | Started |
|---|---|---|---|---|

## Verbindliche Entscheidungen

- macOS 27.x, natives arm64; Xcode 27.1 (27A9275), Swift 6.4 / Sprachmodus 6, SDK 27.
- Kontoloser Ad-hoc-Vertrieb mit Hardened Runtime; keine neuen Entitlements/Abhängigkeiten/Buildphasen.
- Agent besitzt eine Runtime, Schlüsselbund und Kopia; App ausschließlich über authentifiziertes XPC, jetzt Version 5.
- S3: Passwort/AWS-Zugänge als begrenztes Envelope im bestehenden Keychain-Item; keine Credential-Felder in
  Kopia-Verbindungsdateien. HTTPS; HTTP ausschließlich für literales 127.0.0.1 zum lokalen Test.
- S3-Create über `--create-only`; atomare 0600-Connection, explizite Cache-Kapazitäten, Balanced/zstd und Owner.
  Connect beansprucht nur leeren Owner; fremder Owner bleibt erhalten. Keine erzwungene Wartung.
- Credential-Ersatz erst nach Status und frischem Format-Blob-Read; Cache allein zählt nicht als Auth-Nachweis.
- Neue Pläne bleiben manuell bis zur Terminwahl; Mitteilungen standardmäßig aus; Eject nie mit Force.
- Restore ausschließlich in neuen privaten UUID-Ordner (0700), alle Overwrite-Schalter aus. Kein Originalort.
- Snapshot-/Namensauswahl statt Client-Objekt-IDs; exakte Unicode-Namen, getrennte Nutzer-/Sicherheits-Pins.
- Recovery-Kit im nativen Druck-/PDF-Dialog ohne Passwort; Quick Look maximal 50 MB, privater Sitzungscache.
- Normative Architektur/Entscheidungen: PROJEKT.md §6.2–§6.4, §8–§9, §11.2, §12 und §17.

## Implementiert und verdrahtet

- Phase 1/2: gemeinsamer Dienst/Queue/Gate, Keychain, UUID-/FDA-Schutz, Scheduling, Retry/Pausen/Recovery,
  Health, Verify/Test-Restore/Wartung; App/Agent-Menüleiste, DE/EN und sichere Previews.
- Phase 3: Katalog/Browser/Suche, eigener Restore-Task, Fortschritt/Abbruch, Finder/Quick Look und Kit.
  Laufsteuerung und Gate bleiben bis Server-Shutdown/Reaping reserviert, keine Originalquellenprüfung.
- `S3Setup`/`RepositoryCredentials`: begrenzte reflektionsgeschützte Eingabe, frische Keychain-Auflösung.
- `KopiaS3Setup`: neues/verbundenes Ziel ohne persistierte AWS-Felder; bestehende Prozess-/TLS-Bausteine.
  `KopiaFilesystemBinding` prüft S3 über exakte Storage-Allowlist; bestehende Filesystem-Felder kompatibel.
- Gemeinsame Backup-/Restore-/Verify-/Test-Restore-/Wartungsadapter für Dateisystem und S3. Remote-Browse
  ohne lokale Pfade benötigt keine Volume-Überwachung; Restore-Ausgabe und Backup-Quellen behalten UUID-Schutz.
- `S3RepositoryAccess`/`KopiaRepositoryProbe`: frischer authentifizierter Format-Read unter Repo-Reservierung.
- XPC 5: S3-Setup und Credential-Aktualisierung, keine Secret-Rückgabe in Zuständen/Events.
- Assistent: vorhandener Bucket, Endpoint/Region/Präfix, sichere Zugangsfelder und Passwort; DE/EN.
  Speicherziel-Liste mit Credential-Sheet: Ersatz vor Speichern prüfen, fehlerhafte Eingabe behält altes Item.
  Recovery-Kit enthält S3-Metadaten und credentialfreie Verbindungsanleitung.

## Prüfung dieses Codezustands

- Fokussierter echter S3-Lifecycle grün: Create → Backup → Verify/Test-Restore → Neustart → Quelle entfernen →
  Browse/Vollrestore mit Inhaltsvergleich → Connect; falscher Schlüssel/Token/Passwort, Credential-Erhalt,
  Offline-Ablehnung und Secret-Negativscan über reguläre Temp-Dateien. Fremder Owner als zusätzliche Regression.
- `S3ContractTests`: Endpoint-/Secret-/XPC-Grenzen, Reflexionsschutz, CLI-/Server-Environment ohne Secrets in argv,
  exakte Binding-Prüfung und Keychain-Envelope gegen fremde Ziele. Filesystem-Modi/null mit abgedeckt.
- Vollständige Package-Suite: **563 Tests grün** (544 Foundation, 19 Contract), echte temporäre Kopia-Integration.
  Zusätzlich S3 ohne Sitzungstoken: Anlegen, Verbinden und Browser nach frischem Service-Start grün.
- Finales Xcode Debug `build test`: grün, vier Bundle-/Signaturtests; keine neuen Compilerwarnungen.
- Python-Suite: 43 Tests grün. Format-Lint/Diff sauber. Kopia 0.23.1 bleibt SHA256-gepinnt.
- Xcode-First-Launch reparierte fehlendes CoreSimulator-Framework. TLS-Fixtures benötigen den vorhandenen
  TLS-1.3-fähigen Codex-Python über MACKOPIA_TEST_PYTHON, nicht Apples Standard-Python.
- Ein paralleler kalter Xcode-Build ließ zwei vorhandene Integrationstest-Fristen ablaufen; finale Suite separat.
  Zusätzlich eine bestehende Recovery-Test-Race korrigiert: Historie UND freigegebene Queue abwarten,
  dann unverändert dauerhafte Intent-Löschung prüfen. Keine Fristen/Assertions abgeschwächt. Finale Logs: `/tmp/mackopia-p4-{swift,xcode,python,lint}.log`.
- Codefingerprint `0eae2899c61d…` über 452 Dateien: `/tmp/mackopia-p4-code-state.txt`.
- UI-Checkliste §7.8: Systemkomponenten, sichere Defaults, DE/EN, Preview im Code; keine behaupteten
  Live-Screenshots/VoiceOver-/Tastatur-/Drucknachweise. Keine produktiven Konten/Backups berührt.
- Frühere Evidenz: [Phase 3](history/STATUS-Phase3-Abschluss-2026-10-25.md),
  [Phase 2](history/STATUS-Phase2-Abschluss-2026-10-25.md), [Phase 1](history/STATUS-Phase1-Abschluss-2026-10-25.md).

## Offene Live-Nachweise und Grenzen – kein globaler Entwicklungsstopp

| Nachweis | Betroffene Funktion | Exakte nächste Aktion / Besitzer |
|---|---|---|
| Reales S3/IAM/TLS/Token-Ablauf | Provider-Kompatibilität | Nutzer stellt explizit entbehrlichen Bucket/Präfix bereit; Agent prüft Create/Connect/Backup/Restore und Credential-Wechsel |
| S3 Object Lock und spezifische Auth-Diagnose | Optionale Provider-Funktionen/UX | Eigenen Provider-Vertrag nachweisen; aktuell nicht im Assistenten, Fehler bleiben sanitisiert und führen zu Netzwerk-/Zugangsprüfung |
| Installierter Dienst/XPC | SMAppService/Peer-Vertrauen | Nutzer aktiviert gebaute App/Dienst; Agent prüft positive/negative registrierte Peers |
| Login-Keychain/TCC/FDA/Updates | Produktive Secrets/geschützte Quellen | Nutzer + Agent: nur Temp-Ziel, ggf. FDA bestätigen; echte Credential-Aktualisierung und Update-ACL prüfen |
| Safari-Testdatei fehlt oder ist >1 MiB | Konservative FDA-Erkennung | Zugriff gesperrt lassen; begrenzte alternative Kind-Leseprobe entwickeln/nachweisen |
| Reales Unmount/Eject/Abziehen | Hardwarefunktion | Nutzer + Agent: entbehrliches USB-Testvolume, UUID-Wechsel/Veto/Abbruch; kein Force |
| Native Mitteilungen/Aktionen | Zustellung | Nutzer aktiviert am registrierten Dienst; Agent prüft Zustellung/Retry/Details mit Temp-Plan |
| Restore-/S3-UI-Durchgang und Kit/PDF | Fenster, Quick Look, Druck | Agent + Nutzer: lokales Fixture/Temp-Backup, Fehler/Abbruch/Credential-Sheet und PDF-Layout prüfen |
| DE/EN, Light/Dark/Kontrast, Tastatur/VoiceOver | UI-/Releasequalität | Phase 5/6: Screenshots/minimales Fenster und A11y-Audit; bisher Code/Previews/Katalog/Build |
| Harte Dienstbeendigung | Quick-Look-Cache | Private Cache-Reste möglich; Startup-Reinigung ergänzen, regulärer Close/Shutdown bereinigt |
| Große Kataloge/Verzeichnisse | Restore-Browser | >128 Quellen/1.000 Snapshots/8 MiB bzw. >2.000 Einträge blockieren; Pagination vor größerer Freigabe |
| Gatekeeper/Updates, Checkpoint 45 statt 15 Minuten | Release | Phase 6: Installationsartefakt prüfen; Checkpoint-Produktentscheidung treffen |

## Nächster vollständiger Coding-Auftrag

**Phase 4: WebDAV als vollständigen Backend-Block anschließen.**

Vorhandenen freigegebenen anonymen Pipe-/Symlink-/Lock-Transport pro CLI-/Server-Start frisch verwenden;
Keychain, Create/Connect/Testen, Runtime, XPC, Assistent, Offline/Auth/Reconnect und Restore verbinden.
Keine reguläre Secret-Config und keine Kopia-Konfigurationsmutation am Pipe-Transport.
Einstieg: PROJEKT.md §6.2–§6.4, §8–§9, §14 Phase 4, SPIKE-D-SECRETS.md und S3-Komposition als Referenz.
Fertigkriterium: WebDAV über denselben Dienst einrichten, sichern und wiederherstellen; echter temporärer
Lifecycle/Secret-Negativscan, dann Package/Xcode/Format/Doku. Danach SFTP mit bewusster Host-Key-Freigabe.
Name/Bundle-Präfix MacKopia / com.example.MacKopia; Lizenzmodell offen.
