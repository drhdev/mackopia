# Spike D – Backend-Zugangsdaten in Kopia 0.23.1

Stand: 2026-10-23. Reproduzierbar mit:

```bash
/usr/bin/python3 -B Scripts/spike-kopia-secrets.py --output /tmp/mackopia-secrets-spike
```

Der Spike verwendet zufällige Zugangsdaten, ein temporäres Dateisystem-Repository und einen ausschließlich auf
`127.0.0.1` lauschenden HTTP-Testserver. Dessen minimale WebDAV-/S3-Antworten dienen nur der Untersuchung von
Verbindungsaufbau und lokaler Konfiguration. Kein externer Dienst, kein echtes Konto, keine Nutzer-Konfiguration.
HTTP und deaktiviertes TLS sind ausschließlich für diesen kurzlebigen Testserver vorgesehen; keine Produktionsvorgabe.

## Gemessene Ergebnisse

| Backend | Übergabe ohne Secret in argv | Ergebnis |
|---|---|---|
| Dateisystem | `KOPIA_PASSWORD` | Repository-Passwort wird mit `--no-persist-credentials --no-use-keychain` nicht in der Verbindungsdatei gespeichert. |
| WebDAV | `KOPIA_WEBDAV_USERNAME`, `KOPIA_WEBDAV_PASSWORD` | Umgebung wird angenommen; Passwort steht trotzdem im Klartext unter `storage.config.password`. |
| S3 | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | Umgebung wird angenommen; alle drei Werte stehen anschließend im Klartext unter `storage.config`. |
| SFTP | Versuch mit `KOPIA_SFTP_PASSWORD` | Nicht unterstützt. Kopia lehnt den Aufruf vor dem Verbindungsversuch mangels Authentifizierung ab. |

WebDAV und S3 wurden nach dem Löschen ihres temporären Caches mit geänderten Zugangsdaten in der Umgebung erneut
geöffnet. Beide Zugriffe erreichten den Testserver mit der zuvor gespeicherten Identität. Das bloße Aktualisieren
der Prozessumgebung ersetzt die gespeicherten Zugangsdaten daher nicht zuverlässig.

Das Repository-Passwort wurde in keiner der drei erfolgreichen Verbindungsdateien gefunden. In den erzeugten
`.log`-Dateien wurden die zufälligen Test-Secrets nicht gefunden. Das ist eine Prüfung dieser Abläufe, keine allgemeine
Garantie für sämtliche Kopia-Fehlerpfade. Nur ein fest strukturiertes Ergebnis mit Wahrheitswerten und Feldnamen
verlässt das temporäre Verzeichnis; Konfigurationen, HTTP-Header und Kindprozessausgaben werden nicht exportiert.

## Quellcodebeleg zur gepinnten Version

- [S3-CLI](https://github.com/kopia/kopia/blob/v0.23.1/cli/storage_s3.go) und
  [S3-Optionen](https://github.com/kopia/kopia/blob/v0.23.1/repo/blob/s3/s3_options.go): Umgebungsvariablen werden in serialisierbare Optionsfelder übernommen.
- [WebDAV-CLI](https://github.com/kopia/kopia/blob/v0.23.1/cli/storage_webdav.go) und
  [WebDAV-Optionen](https://github.com/kopia/kopia/blob/v0.23.1/repo/blob/webdav/webdav_options.go): gleiches Verhalten für das WebDAV-Passwort.
- [SFTP-CLI](https://github.com/kopia/kopia/blob/v0.23.1/cli/storage_sftp.go): kein Environment-Binding für
  `--sftp-password`; `--keyfile` ist ein möglicher dateibasierter Eingang. `--embed-credentials` würde Schlüsselmaterial einbetten und darf nicht verwendet werden.
- [Verbindungsaufbau](https://github.com/kopia/kopia/blob/v0.23.1/repo/connect.go) und
  [lokale Konfiguration](https://github.com/kopia/kopia/blob/v0.23.1/repo/local_config.go): Storage-ConnectionInfo wird als JSON gespeichert.
  Die `kopia:"sensitive"`-Markierung an Optionsfeldern verhindert diese Serialisierung nicht.

## Konsequenz für die Umsetzung

`--no-persist-credentials` ist kein allgemeiner Schutz vor dem Persistieren von Backend-Secrets. Die bisherige
Annahme „Secret per Umgebung übergeben, normale Kopia-Konfiguration dauerhaft behalten“ erfüllt §8 nicht.
Noch keine Produktionsanbindung von Remote-Zielen implementieren, die auf dieser Annahme beruht.

Als nächstes sichere Zuführung und Lebensdauer von Backend-Secrets untersuchen: S3 ohne gespeicherte statische
Credentials, SFTP mit nicht eingebettetem temporärem Schlüssel und eine Lösung für WebDAV. Falls dabei eine
temporäre secret-haltige Kopia-Konfiguration erforderlich wird, muss deren ausdrückliche Ausnahme von §8 vor
Implementierung festgelegt werden; die allgemeine Temp-Datei-Regel in §6.2 allein klärt diesen Konflikt nicht.

Zum Stand des ersten Spikes nicht geprüft: echte AWS-/S3-/WebDAV-Dienste, S3-Signaturvalidierung durch den Testserver,
SFTP-Anmeldung/Host-Key-Aushandlung, Keychain und verschlüsselte SFTP-Schlüssel/Passphrasen.

## Folge-Spike – Zugänge ohne dauerhafte Secret-Konfiguration

Reproduzierbar mit `python3 Scripts/spike-kopia-secret-input.py --output /tmp/mackopia-secret-input`.
Erfordert wie der Server-Spike einen bereits vorhandenen Python-Interpreter mit TLS 1.3.

### S3: Credential-Felder weglassen

Eine aus der gepinnten Konfigurationsstruktur abgeleitete S3-Konfiguration enthält **keine** Felder
`accessKeyID`, `secretAccessKey` oder `sessionToken`. Kopia kann damit ein bestehendes Ziel über die drei
AWS-Umgebungsvariablen öffnen. CLI und lokaler TLS-Server wurden erfolgreich geprüft; die Konfigurationsdatei
blieb bytegleich und der Server beendete sich mit Exit 0 auf stdin-EOF.

Der lokale S3-Testserver prüft jetzt die SigV4-Signatur der GET-/HEAD-Anfragen einschließlich geheimem Schlüssel
und Sitzungstoken. Zusätzliche echte CLI-Aufrufe mit falschem Schlüssel bzw. falschem Token werden abgelehnt.
Das ist eine minimale Protokollnachbildung für diese Tests; kein Nachweis der Kompatibilität mit jedem S3-Anbieter.

### WebDAV: Konfiguration über eine anonyme Pipe

Die secret-haltigen Optionsfelder werden nur im Speicher zusammengesetzt und über einen explizit vererbten
Pipe-Lesedeskriptor (`--config-file=/dev/fd/<n>`) an Kopia übergeben. stdin bleibt für `--shutdown-on-stdin`
verfügbar. Es gibt für diesen Lauf keine normale Konfigurationsdatei mit dem WebDAV-Passwort.

Gegen echte Kopia-0.23.1-Prozesse geprüft:

- CLI öffnet das bestehende Ziel und liefert den Status.
- TLS-Server öffnet das Ziel; Steuerzugriffe verwenden weiterhin Zertifikat-Pinning und die CSRF-Sitzung.
- Backup nach Dateiänderung und vollständiger REST-Restore erhalten den Dateiinhalt bytegleich.
- Der Server beendet sich auf stdin-EOF mit Exit 0; Pipe-Deskriptor und Writer-Thread werden geschlossen.
- Nach den Abläufen enthalten die verbliebenen temporären Dateien keine der zufälligen Zugangsdaten.

Ein Kontrolllauf verwendet dieselben Daten kurzzeitig in einer normalen Konfigurationsdatei (0600 innerhalb
0700) und löscht sie anschließend im `finally`-Pfad. Dieser Kontrolllauf ist ausschließlich Teil des Spikes;
er führt keine Ausnahme für die Produktionsimplementierung ein. Das Ergebnis-Fixture enthält nur Statuswerte.

Die zuerst beobachteten Shutdown-Hänger traten auch im dateibasierten Kontrolllauf auf. Ursache im Testaufbau:
Dem vereinfachten WebDAV-Server fehlten Schreib-/Umbenennungsoperationen für Kopias Flush beim Beenden.
Nach Ergänzung von PUT/MKCOL/MOVE/DELETE enden **beide** Varianten sauber. Das frühere Hänger-Ergebnis ist
kein Beleg gegen die Pipe-Zuführung.

### Zum Stand des Folge-Spikes noch offen (Fortschritt siehe unten)

- Anlegen/Verbinden neuer Ziele: Die CLI schreibt dort eine Kopia-Konfiguration. Der Pipe-Spike untersucht das
  **Öffnen eines vorhandenen** Ziels; er belegt noch keinen secret-freien Bootstrap eines neuen Remote-Ziels.
- Neustart, Wiederverbindung und Änderungen, die erneut aus der Konfiguration lesen oder sie schreiben.
  Eine Pipe ist nicht seekbar; der Agent müsste sie pro neuem Prozess frisch bereitstellen. Nicht ungeprüft auf
  die gesamte Kopia-Konfigurations-API übertragen.
- Swift-Prozessrunner mit expliziter Descriptor-Vererbung und Abbruch-/Fehlerpfaden sowie Keychain-Anbindung.
- SFTP: Der gepinnte Quellcode liest `--keyfile` und ruft `ssh.ParsePrivateKey` auf; kein eigenes
  Passphrase-Environment-Binding gefunden. Anmeldung, Host-Key-Prüfung und verschlüsselte Schlüssel noch nicht live geprüft.

Sicherheitsinvarianten unverändert. Noch keine Secret-Konfiguration für den Produktionsbetrieb zugelassen.

## Remote-Lebenszyklus – WebDAV neu anlegen und wiederverbinden

Reproduzierbar mit `python3 Scripts/spike-kopia-remote-lifecycle.py --output /tmp/mackopia-remote-lifecycle`.
Der Spike benötigt denselben TLS-1.3-Interpreter und verwendet ausschließlich temporäre lokale Daten.

### Geprüfter Ablauf

1. `repository create webdav --create-only`: Repository- und WebDAV-Passwort ausschließlich aus der Umgebung.
   Es entsteht keine lokale Kopia-Konfigurationsdatei. Wiederholtes Anlegen wird abgelehnt; die Formatdatei bleibt bytegleich.
2. Vollständige Laufzeitkonfiguration im Speicher erzeugen. Cache-Kapazitäten ausdrücklich setzen, wie von Kopia
   generiert: je 5.242.880.000 Bytes für Content/Metadaten und 30 Sekunden List-Cache. Eine nur mit
   `cacheDirectory` gefüllte Konfiguration verursachte in diesem Ablauf einen Kopia-Panic im Content-Cache.
3. Mit jeweils frischer Pipe das Preset „Ausgewogen“ setzen (10/48/14/8/24/3), die Werte wieder auslesen und
   `maintenance set --owner=me` ausführen. Owner anschließend als `test-user@test-host` verifizieren.
   `--create-only` überspringt diese Schritte, weil es vor `populateRepository` zurückkehrt.
4. Initialen Snapshot und reguläre schnelle Wartung ausführen. Server starten, synchronisieren, geänderte Datei
   sichern und bytegleich wiederherstellen. Sauberes Beenden auf stdin-EOF.
5. Server mit frischer Pipe erneut starten, dieselbe Snapshot-ID prüfen, **nur diesen eigenen Testprozess** mit
   SIGKILL beenden. Anschließend erneut verbinden und den abgeschlossenen Snapshot bytegleich wiederherstellen.
   Kein Test eines Absturzes während einer aktiven Sicherung oder des Agent-Prozesses.
6. Falsches Backup-Passwort wird abgelehnt; danach funktioniert der Zugang mit dem richtigen Passwort erneut.
   Abschließender Scan aller temporären Dateien findet keine der zufälligen Zugangsdaten.

### Wartungssperre und Schreibschutz

Ein bloßer `/dev/fd/<n>`-Konfigurationspfad reicht für einen vollständigen Betrieb nicht aus: Kopia verwendet
`ConfigFilename() + ".mlock"` als lokale Wartungssperre. Das schlägt unter `/dev/fd` fehl; ein an sich
abgeschlossener Snapshot kann dadurch einen Fehlerstatus erhalten, wenn anschließend Auto-Wartung startet.

Der neue Spike legt pro Aufruf ein privates Laufzeitverzeichnis mit zwei Symlinks an:

- `repository.config` → `/dev/fd/<geerbter Lesedeskriptor>`
- `repository.config.mlock` → dieselbe reguläre, nicht geheime Sperrdatei im isolierten Zielverzeichnis

Die Sperrdatei hat Modus 0600. Beide Symlinks werden vor dem Start erzeugt, das Laufzeitverzeichnis anschließend
auf 0500 gesetzt. Kopia kann die Konfiguration lesen und die bestehende Sperrdatei öffnen, aber keine
Konfigurationsdatei oder temporäre Datei darin veröffentlichen. Ein tatsächlicher `repository connect webdav`
gegen diesen schreibgeschützten Pfad wird abgelehnt; der Symlink bleibt erhalten. Die Sperrdatei bleibt über
mehrere Prozessstarts dieselbe; ein Unit-Test prüft gegenseitigen Ausschluss mit echten `flock`-Aufrufen.

Nach Prozessende wird der Verzeichnismodus für das Cleanup auf 0700 zurückgesetzt und das Laufzeitverzeichnis
entfernt. Ein Prozessabsturz allein hinterlässt keine JSON-Datei mit Credentials. Agent-Absturz, Start-Cleanup
verwaister Laufzeitverzeichnisse und der produktive Swift-Descriptor-Transport sind noch nicht geprüft.
Der Modus 0500 schützt gegen versehentliche Schreibversuche des unveränderten Kopia, nicht gegen beliebige
bösartige Prozesse desselben Benutzers, die Verzeichnisrechte ändern könnten.

`POST /repo/description` scheitert erwartungsgemäß am erneuten Lesen einer verbrauchten Pipe; die bestehende
Verbindung bleibt danach nutzbar. Solche Einstellungen muss der Agent außerhalb des Kopia-Konfigurations-APIs
verwalten und beim nächsten Prozessstart neu einspielen. Der Test schreibt keine Secrets als Ausweichlösung.

Für die Backend-Testantworten werden nun echte Blob-mtime-Werte verwendet: feste Zeitstempel aus 2023 waren
für Kopias Clock-Skew-Prüfung der Wartung ungeeignet. Das ist eine Korrektur des Testservers.

### Freigabe für Produktionsintegration (2026-10-23)

Der Nutzer hat die auf WebDAV begrenzte Präzisierung bestätigt. [AGENTS.md §2.4](../AGENTS.md) sowie
PROJEKT.md §6.2/§8/§17 erlauben jetzt die nur speicherbasierte Übergabe: Der Agent darf Credentials aus dem
Schlüsselbund in einer im Speicher erzeugten Kopia-Laufzeitkonfiguration über eine explizit vererbte anonyme
Pipe übergeben. Keine secret-haltige reguläre Konfigurations-/Temp-Datei. Geschützter Symlink-Pfad,
gemeinsame nicht geheime Wartungssperre, frische Pipe pro Prozess und Cleanup sind verbindlich.
Kopia-Konfigurations-Schreiboperationen bleiben ausgeschlossen.

Weitere offene Punkte: S3-Bootstrap gegen ein schreibbares Backend, SFTP, Keychain, vollständiger Swift-Prozessrunner,
Crash während aktiver Sicherung und echte Remote-Anbieter.

### Swift-Grundlage nach Freigabe

`KopiaCLI/KopiaConfigurationPipe.swift` setzt die Descriptor-/Symlink-/Lock-Lebensdauer als internen
Baustein um. Sieben native Tests prüfen unter anderem vollständige 64-KiB-Übergabe, EOF, Abbruch,
Schreibschutz und echte explizite Vererbung an einen Hilfsprozess. Dieser Baustein ist noch nicht in
einen vollständigen Swift-Kopia-Prozessrunner oder den Schlüsselbund eingebunden. Der erneut erfolgreiche
WebDAV-Lebenszyklus verwendet weiterhin den Python-Spike und ist kein Beleg für diese ausstehende Integration.

### Native CLI-Anbindung

Der interne `KopiaProcess` nutzt jetzt den Swift-Pipe-Baustein. Ein echter nativer Integrationstest erzeugt
ein neues WebDAV-Ziel ohne lokale Secret-Konfiguration und öffnet es zweimal mit frischer Pipe. Statusausgaben
und verbliebene Testdateien enthalten keine der zufälligen Passwörter. Konfigurations-Deskriptoren werden explizit
vererbt; der Eltern-Reader wird nach Spawn geschlossen. Früh beendete Prozesse können den Writer dadurch
nicht blockieren. Der langlebige Kopia-Server und der Schlüsselbund sind weiterhin nicht angebunden.

Für das CLI-Status-JSON gilt `storage.type`; die Felder unterscheiden sich vom REST-Status:
[geprüfter Quellcode v0.23.1](https://github.com/kopia/kopia/blob/v0.23.1/cli/command_repository_status.go).


### S3-Produktionsintegration (2026-10-25)

Der S3-Pfad ist jetzt im Swift-Dienst, XPC-5-Assistenten und Restore integriert. `KopiaS3Setup` verwendet
Create-only und eine atomar publizierte credentialfreie Connection; `RepositoryCredentials` lädt das
Passwort-/AWS-Envelope frisch aus dem Schlüsselbund. Ein zusätzlicher Format-Blob-Read verhindert,
dass lokale Cache-Evidenz allein als Authentifizierung eines Credential-Ersatzes gilt.

`S3ServiceIntegrationTests` prüft gegen eine wegwerfbare SigV4-/Chunk-signaturprüfende Nachbildung Create,
Backup/Verify/Test-Restore, Neustart, Restore ohne Original, Connect mit erhaltenem fremdem Owner,
falsche Schlüssel/Tokens/Passwörter, abgelehnten Credential-Ersatz, Offline-Zustand und Secret-Persistenz.
Ein eigener Durchstich prüft Zugriffsschlüssel ohne Sitzungstoken. Aktuelle Ergebnisse/Live-Grenzen:
[STATUS.md](STATUS.md). Echte Provider/IAM/Object-Lock und installierter Keychain-Betrieb bleiben separat.
