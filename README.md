# MacKopia

Native macOS backup app (SwiftUI, macOS 27 only, Apple silicon) built on the [Kopia](https://kopia.io) backup engine —
*Time Machine simple, Arq reliable*.

> Status: local app–XPC–service backup workflow implemented and automatically tested; installed service and UI audit remain open. See [`docs/STATUS.md`](docs/STATUS.md).

- Specification (German): [`docs/PROJEKT.md`](docs/PROJEKT.md)
- Contributor & agent rules: [`AGENTS.md`](AGENTS.md) (Claude Code additionally reads [`CLAUDE.md`](CLAUDE.md))

Kopia is licensed under the Apache License 2.0 and is bundled as an unmodified binary.

Current implementation: [`docs/IMPLEMENTIERUNG.md`](docs/IMPLEMENTIERUNG.md). Follow the outcome-based
phases in PROJEKT.md §14 and the block-boundary testing/context workflow in AGENTS.md §5.
Read compact status and relevant spec sections; historical transcripts are archived, not startup context.

## S3 destinations

The setup assistant can create or connect an encrypted destination in an existing S3-compatible bucket.
Enter an HTTPS endpoint without a path, bucket, region, optional prefix, access key, secret key and optional
session token, together with the separate backup password. Limit provider permissions to the selected prefix.
Setup tests access; new plans remain manual until you choose a schedule.

The agent stores credentials in the login Keychain and supplies them only through child-process environment
variables. Its connection file contains no AWS credential fields. Under Destinations, **Update credentials…**
tests replacements before saving them. Backup, verification, maintenance and restore share the existing
service runtime and repository reservation. Recovery kits include connection metadata without credentials.

A complete lifecycle is tested against disposable local SigV4-authenticated storage. Compatibility with a real
provider and its IAM policy, installed Keychain behavior, and manual UI/PDF review still require live evidence.
Object Lock setup is not exposed yet. Plain HTTP is accepted only for the literal loopback test address 127.0.0.1.

## Development

Use the latest stable Xcode and its bundled Swift/SwiftUI SDK (verified baseline: Xcode 27.1, Swift 6.4, macOS 27 SDK).
Open `MacKopia.xcodeproj` and select the shared `MacKopia` scheme.
The UI and menu bar connect local setup, plan editing, manual backup/stop, status and history to the background service.
Automatic scheduling and the full restore browser are integrated; WebDAV and SFTP are the next backend integrations.
Only macOS 27.x on arm64 is supported: no Intel/Rosetta or older-OS compatibility paths.
The service is embedded under `Contents/Library/LoginItems`; the matching job plist is generated
under `Contents/Library/LaunchAgents`. Service registration is explicit through the app and Settings UI.

```bash
swift test --package-path MacKopiaKit
swift format lint --recursive --strict App Agent MacKopiaKit Tests
xcodebuild -scheme MacKopia -destination 'platform=macOS' build test
```

MacKopia targets distribution outside the App Store without an Apple Developer account,
Developer ID certificate or mandatory notarization. App, Agent and embedded Kopia use local
ad-hoc signatures (`-`) with Hardened Runtime; the team remains empty. No Apple signing
identity, provisioning profile or additional entitlements are needed. For a regular Gatekeeper
warning, users can explicitly approve the downloaded app under System Settings → Privacy &
Security → Open Anyway. Download/quarantine installation still needs release testing.
Xcode's separate debug dylib is disabled because ad-hoc code cannot meet its team-based
library validation. Bundle tests run outside the protected app, without relaxing product security.
The build fetches SHA256-pinned Kopia 0.23.1 archives, uses only the native arm64 helper,
and embeds it at `Contents/Helpers/kopia`. Apache license text and the upstream README
are included in `Contents/Resources/Kopia`. Downloads are cached under ignored `Vendor/`.
Run `./Scripts/fetch-kopia.sh` to prepare the helper independently. A cached archive with
a mismatched hash fails the build; remove that archive explicitly before retrying.
The `AgentProtocol` module contains version-2 bounded service requests, revision-based status updates,
reconnect support and the `SMAppService` registration boundary. The older ping remains a contract fixture.
Both client and listener pin the exact peer signing identifier and CodeDirectory hash from
the validated installed bundle. The running executable must match its own disk signature;
invalid or unsigned code fails closed. The listener starts with the Agent. Live registration,
positive/negative App–Agent connection, download installation and TCC/FDA behavior still need verification
with the ad-hoc distribution build. The agent uses the local login Keychain without team/access-group
entitlements or a credential-file fallback. Fresh protected-file probes must succeed in both the agent
and bundled Kopia before source access is admitted. Tests do not register a persistent background service.

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
The long-lived server, Keychain adapter, domain mapping and App/Agent workflow are now integrated;
installed service/Keychain permissions and provider-specific behavior still need live acceptance.
See the current implementation atlas and status for the authoritative integration state.
