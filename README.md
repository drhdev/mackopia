# MacKopia

Native macOS backup app (SwiftUI, macOS 26+) built on the [Kopia](https://kopia.io) backup engine —
*Time Machine simple, Arq reliable*.

> Status: Phase 0 foundation in progress. See [`docs/STATUS.md`](docs/STATUS.md).

- Specification (German): [`docs/PROJEKT.md`](docs/PROJEKT.md)
- Contributor & agent rules: [`AGENTS.md`](AGENTS.md) (Claude Code additionally reads [`CLAUDE.md`](CLAUDE.md))

Kopia is licensed under the Apache License 2.0 and is bundled as an unmodified binary.

## Development

Open `MacKopia.xcodeproj` in Xcode 26 or newer and select the shared `MacKopia` scheme.
The initial app and menu bar service are development placeholders; no backups run yet.
The service is embedded under `Contents/Library/LoginItems`; the matching job plist is generated
under `Contents/Library/LaunchAgents`. Service registration is explicit and has no UI control yet.

```bash
swift test --package-path MacKopiaKit
swift format lint --recursive --strict App Agent MacKopiaKit Tests
xcodebuild -scheme MacKopia -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme MacKopia -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

Apple development signing, Developer ID signing and notarization are deferred to later releases;
no Apple Developer account or certificate is required for current independent development.
Shared defaults use `com.example`, an empty team and `CODE_SIGNING_ALLOWED=NO`. Fetch/embed scripts
also skip explicit signing unless `CODE_SIGNING_ALLOWED=YES`; builds do not configure an Apple identity.
Upstream binaries or the linker can already supply ad-hoc code signatures; these cannot satisfy team-based XPC checks.
Distribution signing will be configured later in the ignored `Config/Local.xcconfig`.
The build fetches SHA256-pinned Kopia 0.23.1 archives, creates a universal helper,
and embeds it at `Contents/Helpers/kopia`. Apache license text and the upstream README
are included in `Contents/Resources/Kopia`. Downloads are cached under ignored `Vendor/`.
Run `./Scripts/fetch-kopia.sh` to prepare the helper independently. A cached archive with
a mismatched hash fails the build; remove that archive explicitly before retrying.
The `AgentProtocol` module contains the signed XPC ping and the `SMAppService` registration boundary.
Both client and listener require a valid team signature and an exact peer signing identifier;
ad-hoc builds fail closed. The listener starts with the Agent. UI wiring and successful signed
registration/ping, including TCC/FDA behavior, still need verification after signing is configured.
Protocol and registration error paths are covered without installing a system service.

The Phase-0 filesystem probe creates an isolated temporary repository, backs up generated
files, restores to a new directory, verifies every file, and records metadata observations:

```bash
./Scripts/spike-kopia-cli.py --output /tmp/mackopia-spike-results
/usr/bin/python3 -B -m unittest discover -s Scripts/tests
```

Recorded and scrubbed CLI fixtures live under `MacKopiaKit/Tests/Fixtures/kopia-0.23.1`.
The initial probe preserves file data, symlinks, modes and modification times, but observes
missing extended attributes, Finder tags, ACLs and resource forks after restore. These
are known limits of this tested workflow, not guarantees of complete macOS metadata backup.

The server probe checks TLS 1.3 and leaf-certificate pinning, Basic Auth and CSRF,
creates a snapshot through REST, estimates and restores its files, and verifies stdin-EOF shutdown:

```bash
python3 Scripts/spike-kopia-server.py --output /tmp/mackopia-server-spike-results
```

This development probe requires a Python interpreter with TLS 1.3 support (`ssl.HAS_TLSv1_3`).
Apple's `/usr/bin/python3` on the development machine lacks it; use an already available
compatible `python3`. No third-party Python modules are required. Both probes create only
temporary repositories; the server listens only on `127.0.0.1` with a random port and credentials.
Neither certificates nor credentials nor CSRF session values are written into the recorded fixtures.

The cancellation probe generates 128 random files (256 MiB) in a temporary repository,
records active upload counters, cancels through REST, restarts the server and verifies
reuse of the incomplete snapshot, a full byte-identical restore and 100% file verification:

```bash
python3 Scripts/spike-kopia-cancel.py --output /tmp/mackopia-cancel-spike-results
```

It requires the same TLS 1.3 interpreter as the server probe. Cancellation waits for pending
writes to flush. Kopia 0.23.1 exposes `--checkpoint-interval` only on CLI snapshot creation;
the unmodified server keeps its 45-minute default. The planned 15-minute server interval
remains unresolved. Cached-file counts demonstrate durable reuse; timings do not establish
a controlled cold-run speed comparison.


The backend probes reproduce credential persistence and test alternatives without external accounts:

```bash
python3 Scripts/spike-kopia-secrets.py --output /tmp/mackopia-secrets-spike
python3 Scripts/spike-kopia-secret-input.py --output /tmp/mackopia-secret-input
```

The second command requires TLS 1.3. S3 can open an existing destination using environment credentials
with all credential fields absent from its config. WebDAV can receive an in-memory config over an inherited
anonymous pipe: CLI access, server backup/restore and clean EOF shutdown are verified. The fixture S3 server
checks SigV4 signatures and rejects wrong secrets/tokens. Both backends are served on loopback only; plain
HTTP is confined to the disposable backend fixture. The Kopia control server still uses pinned TLS.
A disposable file-backed WebDAV control run is also tested and immediately cleaned up. These are feasibility
probes, not production integration; destination creation, reconnect/configuration changes and SFTP remain open.
See [`docs/SPIKE-D-SECRETS.md`](docs/SPIKE-D-SECRETS.md).


The WebDAV lifecycle probe creates a fresh destination with `--create-only`, explicitly initializes retention
and the maintenance owner, verifies quick maintenance, and reconnects after a forced server exit:

```bash
python3 Scripts/spike-kopia-remote-lifecycle.py --output /tmp/mackopia-remote-lifecycle
```

It uses fresh inherited pipes behind private read-only runtime paths and one shared maintenance lock.
It verifies byte-identical restore, rejects wrong passwords and prevents publishing a secret config file.
The WebDAV memory-only JSON/pipe transport is approved in AGENTS.md §2.4. The full lifecycle above
remains a probe; production process and Keychain integration are still pending.
It does not test a crash during an active backup or a real remote provider.

The internal Swift `KopiaProcess` executes finite CLI commands with an explicit environment whitelist,
separate bounded stdout/stderr capture, per-command deadlines and cancellation escalation through
SIGINT/SIGTERM/SIGKILL. It owns and reaps its process group. `KopiaConfigurationPipe` supplies fresh WebDAV
memory-only configurations with protected runtime symlinks and a shared maintenance lock. Typed commands
currently cover repository status and maintenance information; config/cache/log locations are UUID-based
and separate. Results and requests redact their debug reflection; raw child output must stay private.

Native integration tests use the pinned binary and disposable filesystem/WebDAV destinations. They run
when the fetched binary is available; CI sets `MACKOPIA_REQUIRE_KOPIA_INTEGRATION=1` to prevent silent skips.
`swift test --package-path MacKopiaKit --filter Integration` runs that suite after fetching Kopia.
Long-lived server stdin/handshake ownership, PID-file recovery, Keychain, domain DTO/error mapping and
App/Agent wiring remain pending. The app still does not perform backups.
