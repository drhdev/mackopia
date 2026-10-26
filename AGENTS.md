# AGENTS.md — MacKopia

Shared instructions for **every** coding agent working in this repository (Claude Code, OpenAI Codex, others) and for humans.
`CLAUDE.md` imports this file. **Keep all shared rules here**, never duplicate them into agent-specific files.

---

## 1. What this project is

MacKopia is a native **macOS 27-only, Apple-silicon** backup app using the latest stable Xcode, its Swift compiler and SwiftUI SDK, and the bundled
[Kopia](https://kopia.io) CLI/server as its engine. Goal: *Time Machine simple, Arq reliable*.

- **Source of truth for scope, architecture and phases:** [`docs/PROJEKT.md`](docs/PROJEKT.md) (German).
  Read the relevant section **before** you start a task. If code and spec disagree, the spec wins — or you update the spec
  in the same change and add a row to its decision log (§17).
- **Current progress / who is doing what:** [`docs/STATUS.md`](docs/STATUS.md), a compact restart document.
  **Implemented baseline:** [`docs/IMPLEMENTIERUNG.md`](docs/IMPLEMENTIERUNG.md). Update both after each substantial work block.
- Start with these instructions, compact status, PROJEKT.md §14 and only the spec sections/source files relevant to the next block.
  Never load the full historical log or full spec by default. Historical evidence lives in `docs/history/`.
- `continue coding` means execute the next substantial deliverable from §14 autonomously, including integration and documentation;
  continue through internal subtasks without asking for another `continue`. Context compaction is a checkpoint, not completion.
- UI language: German (development language) + English, via String Catalog. Code, comments, commits, identifiers: **English**.
  Specs in `docs/` are German.

---

## 2. Non-negotiable invariants

Breaking one of these is a bug, even if tests pass.

1. **Never lose or corrupt user data.** Restores never overwrite silently; destructive actions need explicit confirmation.
   Never run `kopia repository upgrade`, `snapshot delete`, `maintenance --full --safety=none` or similar without an explicit user action.
2. **The Agent owns Kopia.** Only the background agent (`Agent/`) spawns `kopia` and writes configuration. The UI app talks to it
   via XPC only. **The `App` target must never import `KopiaCLI` or `KopiaServer`.**
3. **Isolated Kopia state.** Always pass `--config-file` and `--log-dir` for our per-repository directories.
   Kopia 0.23.1 accepts `--cache-directory` on `repository create/connect` and `server start` (not globally): set it there, then use the stored
   cache path in the isolated config and set `KOPIA_CACHE_DIRECTORY` on every child process.
   Never read from or write to the user's default Kopia config (`~/Library/Application Support/kopia/`) except in the explicit,
   read-only import flow.
4. **Secrets only in the Keychain.** Never put passwords, keys or tokens in argv, `UserDefaults`, JSON config, logs, XPC events,
   crash reports, test fixtures or commit history. Pass them to child processes via environment variables.
   WebDAV/SFTP exception (WebDAV approved 2026-10-23, SFTP approved 2026-10-26): the Agent may encode a runtime JSON configuration only in memory
   and pass it through an explicitly inherited anonymous pipe. Never write it to a regular config/temp file.
   Use a fresh pipe per process, a protected runtime symlink directory and a shared nonsecret maintenance lock;
   clean up descriptors/directories and prohibit Kopia config read/modify/write commands on this transport.
5. **No shell.** Spawn processes with an argument array; never `/bin/sh -c`, never string-interpolate paths into commands.
6. **Identity by UUID, not by name.** Volumes are identified by volume UUID. Never back up from or to a path whose volume UUID
   does not match the stored one (empty `/Volumes/X` mount-point trap).
7. **Scheduling lives in MacKopia only.** Never set Kopia `scheduling` policies.
8. **Kopia version is pinned** in `Config/kopia-version.json`. Changing it requires updated contract fixtures and green integration tests.
9. **Local Kopia server is loopback-only, TLS with fingerprint pinning, random credentials, `--shutdown-on-stdin`.** No ATS exceptions,
   no "accept any certificate" code, not even in Debug.
10. **Hardened Runtime on, App Sandbox off, minimal entitlements.** Do not add entitlements without a decision-log entry.

---

## 3. Repository layout

```
docs/                  PROJEKT.md (spec), STATUS.md (progress), decision log lives in PROJEKT.md §17
App/                   UI app target (SwiftUI). Features/<Feature>/{Views, Store}.  No business logic in views.
Agent/                 Background agent target (LSUIElement): engine host, XPC server, MenuBarExtra
MacKopiaKit/           Local Swift package — ALL logic. Modules: BackupDomain, KopiaCLI, KopiaServer, BackupEngine,
                       Persistence, Secrets, SystemIntegration, AgentProtocol, TestSupport
Scripts/               fetch-kopia.sh, embed-kopia.sh, future release packaging/appcast scripts
Config/                xcconfigs, kopia-version.json
Vendor/                downloaded kopia binaries (git-ignored, produced by Scripts/fetch-kopia.sh)
```

Dependency direction is enforced by package targets (see PROJEKT.md §5.2). Do not add cross-imports that violate it.
Allowed third-party dependencies: **Sparkle 2, GRDB** (optionally `swift-subprocess` once ≥ 1.0). Anything else → ask first and log it.

---

## 4. Commands

> Run the relevant checks at substantial block/phase boundaries according to §5, not after every small edit.

```bash
./Scripts/fetch-kopia.sh                                  # fetch + verify pinned arm64 Kopia (cached)
swift test --package-path MacKopiaKit                     # package suite, including available integration tests
swift test --package-path MacKopiaKit --filter Integration   # integration tests against the real kopia
xcodebuild -scheme MacKopia -destination 'platform=macOS' build
xcodebuild -scheme MacKopia -destination 'platform=macOS' test   # bundle/signature tests; UI smoke when implemented
swift format lint --recursive --strict App Agent MacKopiaKit     # must be clean
swift format --in-place --recursive App Agent MacKopiaKit
```

Before a code block is complete, run its required verification once on the final code state, with **zero new compiler warnings**.
Documentation-only blocks need document/link/diff checks, not Swift/Xcode rebuilds. See §5 for the test cadence.

---

## 5. Collaboration between agents (Claude Code ↔ Codex)

- **One substantial deliverable = one branch = one PR.** Branch names: `<agent>/<phase>-<topic>`, e.g. `claude/p1-kopia-process`, `codex/p5-plan-editor`.
  Humans use `feat/…`, `fix/…`. Never push directly to `main` except for the initial repository bootstrap.
- **Claim work before starting:** add yourself to the "In progress" table in `docs/STATUS.md` (task, branch, files/modules touched).
  Do not start work on files another open task has claimed; pick something else or coordinate via the PR.
- Keep commits logical and PRs reviewable. Do not turn an arbitrary line-count target into unintegrated adapters or user-visible
  microtasks. A coherent multi-module feature may exceed 400 lines; organize its review by behavior and affected modules.
- **Commits:** Conventional Commits — `feat(engine): …`, `fix(kopia-server): …`, `test: …`, `docs: …`, `chore: …`, `refactor: …`.
  Imperative mood, body explains *why*. Add the attribution trailer your harness requires.
- **Cross-review:** a PR authored by one agent should preferably be reviewed by the other agent or a human before merge.
- **Hand-off note:** at the end of a session, update `docs/STATUS.md` → what is done, what is next, open questions, gotchas found.
  Assume the next agent has none of your context.
- **Decisions** that change the spec go into PROJEKT.md §17 in the same PR. Kopia quirks you discover go into a code comment
  with the Kopia version, *and* into §17 if they affect design.
- Never rewrite shared history (`push --force` on `main` or someone else's branch). Rebase only your own branch.
- If you are unsure about a product or UX decision, **ask the user** instead of guessing; record the answer in §17.

### Autonomous blocks, verification and context

- Follow the outcome-based phases in PROJEKT.md §14. Build complete usable behavior, not one helper per user turn.
  Do not reopen the historical Phase-0 gate or wait on unrelated release checks before implementing independent work.
- Plan briefly in the same working turn, then implement all authorized dependent steps. Ask only for unresolved consequential
  product decisions, destructive actions, new dependencies/entitlements or a real external blocker; continue independent work.
- User-confirmed on 2026-10-25: targeted diagnosis is allowed inside a large block.
  Write meaningful tests alongside logic, but batch execution: during a block, compile or run a narrowly targeted test only to
  resolve concrete uncertainty, reproduce a bug or diagnose a failure. No automatic full-suite cycle after each type/file/adapter.
- At a substantial code-block or phase boundary: format/lint, one full package run (real temporary Kopia integration included when
  engine/process code or its configuration changed), and one Xcode `build test` when app/agent/build/IPC paths are affected.
  Run Release/signature/packaging checks when those paths changed or at release preparation. Do not rerun unchanged Python spikes,
  integration scenarios or whole suites already covered by the same final state. Repeat only after relevant changes or failures.
- Never defer a known data-loss/secret/authentication issue to save tokens. Block only the affected live operation while fixing or
  recording a real permission/environment dependency; do not weaken assertions, fake evidence or label untested behavior verified.
- Manual FDA/registration/Gatekeeper/A11y/hardware checks form a separate evidence ledger, not a global development lock.
  Record owner, affected function, exact next action and last evidence; perform them once the integrated path exists.
- Keep STATUS.md approximately ≤120 lines and IMPLEMENTIERUNG.md approximately ≤160 lines. They describe current state, not a
  growing transcript. Archive old session narratives with an index; never erase evidence. Keep detailed logs in files, return summaries.
- Each checkpoint records: phase/deliverable, implemented and wired behavior, important files/API boundaries, verification with
  code state/toolchain, actual open risks, and one executable next assignment with finish criteria and required spec sections.
  Update normative architecture and decisions in PROJEKT.md as needed; don't duplicate session narratives there.
- Before context gets large, finish a coherent checkpoint, persist this handoff and proceed using the compact documents after
  compaction. Do not ask the user to open a new chat merely to continue. Do not claim unlimited context or background execution.

---

## 6. Swift & architecture standards

**Platform & toolchain**
- Support macOS 27.x on native arm64 only; minimum deployment target 27.0. No macOS 26/Intel/Rosetta compatibility work,
  older-OS fallback transports, deprecated APIs or availability branches below the supported target.
- Use the latest stable Xcode and its bundled Swift/SwiftUI/macOS SDK. Current verified baseline: Xcode 27.1, Swift compiler 6.4,
  Swift 6 language mode, macOS 27 SDK. SwiftUI has no independently selected version. Do not switch to beta/RC automatically.
  Record toolchain upgrades at block boundaries; keep reproducible dependencies and the pinned Kopia version intact.
- Prefer current native system APIs where they simplify behavior, improve efficiency or accessibility. No speculative framework,
  entitlement, background mode, App Intent or architectural rewrite without a concrete feature need. Preserve working module boundaries.

**Language & concurrency**
- Swift 6 language mode, strict concurrency `complete`. App + Agent targets use `Default Actor Isolation = MainActor`.
  Package modules are nonisolated by default; shared mutable state lives in `actor`s.
- No `@unchecked Sendable`, no `nonisolated(unsafe)` without a comment that proves safety. No `DispatchQueue`/`DispatchSemaphore`
  in new code except at AppKit/IOKit/DiskArbitration boundaries (wrap them in an `AsyncStream`).
- Long work is cancellable: check `Task.isCancelled` / use `withTaskCancellationHandler`; child processes are terminated on cancellation.
- Inject time (`any Clock<Duration>`), file system, process runner and Keychain behind protocols so the engine is testable.

**State & UI architecture**
- `@Observable @MainActor final class <Feature>Store` per feature; views get stores via `@Environment`. One app-wide
  `AgentConnection` store owns the XPC session and fans events out.
- Views are dumb: no XPC calls, no file system, no formatting logic beyond `FormatStyle`. No singletons accessed from views.
- Use `@State` only for view-local UI state, `@Bindable` for editing store models. No `ObservableObject`/`@Published` in new code.
- Navigation via value-based `NavigationSplitView` selection; deep links via an `enum Route: Hashable`.

**Code quality**
- No `try!`, no force unwraps, no `fatalError` outside of `preconditionFailure` for programmer errors. No `print` — use `os.Logger`.
- Errors are typed enums conforming to `LocalizedError` with a localized user message and a technical `debugDescription`.
- `Logger` interpolations: paths and user data `privacy: .private`; secrets are **never** logged at all.
- Prefer value types; `final class` when reference semantics are needed. Access control: `internal` by default, `public` only for module APIs.
- Files: one primary type per file, ≤ ~300 lines; views ≤ ~200 lines (extract subviews). Name files after the type.
- Comments explain *why*, not *what*. Each Kopia workaround gets `// Kopia 0.23.1: …`.
- Every SwiftUI view has a `#Preview` using mock stores (`PreviewData` in each feature). Previews must not touch the real agent.

**Testing**
- Swift Testing (`@Test`, `#expect`, `@Suite`, tags `.integration`, `.slow`). XCTest only for XCUITest.
- New logic ⇒ new tests in the same PR. Bugs ⇒ a failing regression test first.
- Kopia JSON/REST responses are tested against recorded fixtures in `MacKopiaKit/Tests/Fixtures/kopia-<version>/`.
  Fixtures must be scrubbed of passwords, real paths and hostnames.
- Integration tests create repositories only under a temp directory and clean up after themselves.

---

## 7. Design, UX and look & feel (macOS-native standard)

The app must feel like it was made by Apple: calm, obvious, trustworthy. When in doubt, copy what **System Settings, Finder,
Time Machine and Mail** do on macOS 27, and follow the [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/).

### 7.1 Principles
1. **Status first.** The user must answer "Am I safe?" within one second: overview + menu bar show a clear state
   (OK / warning / critical) with a short reason and the time of the last successful backup.
2. **Zero-config by default, power on demand.** Sensible defaults everywhere; advanced options live behind
   `DisclosureGroup("Erweitert")` or an "Advanced" settings pane. A first-time user must reach a running backup in < 3 minutes.
3. **Every problem has a next step.** No dead ends: each warning/error shows *what happened*, *why it matters*, and a button that fixes or explains it.
4. **Never surprise, never scare.** No modal interruptions for routine events. Confirm only destructive or irreversible actions.
5. **Calm motion.** Animations are subtle and functional (state changes, progress). Respect "Reduce Motion".

### 7.2 Use system components only
- Window structure: `NavigationSplitView` (sidebar → content → optional `.inspector`). Sidebar uses `List` with `Section`s and
  `Label` rows; default sidebar width; no custom sidebar backgrounds.
- Data: `Table` for tabular data (snapshots, activity) with sortable columns and context menus; `List` for simple collections.
- Settings & editors: `Form` with `.formStyle(.grouped)`, `LabeledContent`, `Toggle`, `Picker`, `Stepper`, `DatePicker`.
  App preferences live in a `Settings` scene (⌘,), never in a custom window.
- Actions: `.toolbar` with `ToolbarItem`/`ControlGroup`, primary action as `.borderedProminent` only once per view.
  Menu commands via `.commands` with standard shortcuts.
- Feedback: `ProgressView` (determinate when possible), `Gauge` for capacity, `ContentUnavailableView` for empty states,
  `.alert` for errors that block the user, `.confirmationDialog` for destructive actions, `.sheet` for focused multi-step tasks
  (wizards, restore), `.popover` for small contextual info. Never stack sheets.
- System panels: `NSOpenPanel`/`.fileImporter`, `QLPreviewPanel` (Quick Look), `NSWorkspace` for "Show in Finder".
- Menu bar: `MenuBarExtra` with `.menuBarExtraStyle(.window)`; template SF Symbol icon (monochrome), state via symbol variant.

### 7.3 Liquid Glass (macOS 27)
- Let the system apply Liquid Glass to toolbars, sidebars, sheets, menus and controls. **Do not** paint custom backgrounds,
  materials or gradients behind them, do not hide the toolbar background, do not fake glass.
- Use `.glassEffect` / `GlassEffectContainer` only for a rare custom floating control (e.g. the progress panel accessory), never for content.
- Content areas use default window backgrounds; group content with `Form`/`Section`/`GroupBox`, not custom cards with shadows.
  If a dashboard tile is needed, use a plain rounded rectangle with `.background(.background.secondary)` and the system corner radius.

### 7.4 Visual details
- **Typography:** only system text styles (`.largeTitle` … `.caption2`), never fixed point sizes. Monospaced digits
  (`.monospacedDigit()`) for changing numbers (bytes, speed, time). Long paths: `.truncationMode(.middle)`, full path in `.help()` tooltip.
- **Color:** semantic colors only (`.primary`, `.secondary`, `.tint`, `Color(.systemRed)` …). Respect the user's accent color;
  no custom brand palette in the UI chrome. Status colors: green = OK, yellow/orange = warning, red = critical — **always paired with
  an icon and text** (never color alone). Light, dark and "Increase Contrast" must all look correct.
- **Icons:** SF Symbols only (consistent rendering mode, usually `.hierarchical`), with `.symbolEffect` for running states
  (respects Reduce Motion automatically). App icon follows the macOS 27 icon grid (Icon Composer, layered for glass).
- **Spacing & layout:** system default padding and spacing; no magic numbers except multiples of 4. Minimum window size such that
  nothing truncates in German (German strings are ~30 % longer — test with the longest language). Remember window size/position
  and sidebar selection (`@SceneStorage`).
- **Empty states** tell the user what to do: "Noch kein Backup-Plan — Erstelle deinen ersten Plan" + button.

### 7.5 Interaction
- Full keyboard operation: every action reachable via menu bar + shortcut. Standard shortcuts: ⌘N new plan, ⌘B back up now,
  ⌘. stop, ⌘R restore, ⌘, settings, Space = Quick Look in restore browser, ⌫ = remove selected source (with undo where possible).
- Drag & drop folders from Finder onto the source list. Context menus on all list/table rows, mirroring toolbar actions.
- Undo (`UndoManager`) for non-destructive edits in editors (removing a source, changing retention) where feasible.
- Long operations never block the UI; show inline progress, keep the window interactive, allow cancel.
- Live progress updates at most ~4×/s; no flicker; ETA appears only after it is stable.
- Destructive buttons use `role: .destructive`; default button is the *safe* choice.

### 7.6 Accessibility (release blocker)
- Every control has a meaningful label; icon-only buttons have `.help()` **and** `.accessibilityLabel`.
- Progress exposes `accessibilityValue` ("41 Prozent, noch etwa 18 Minuten"); status badges read their state in words.
- Supports VoiceOver, Full Keyboard Access, Dynamic Type sizes available on macOS, Reduce Motion, Reduce Transparency,
  Increase Contrast. Verify with Accessibility Inspector in the integrated UI/release audit; record any unperformed manual checks without blocking unrelated implementation.

### 7.7 Copy & localization
- All user-facing strings go through `Localizable.xcstrings` (German source, English complete). Use `String(localized:)` / `LocalizedStringKey`;
  no concatenated sentences; plurals via the catalog; numbers/dates/bytes via `FormatStyle` (`.byteCount(style: .file)`, `.relative`).
- German tone: friendly, short, address the user as **„du“** consistently; prefer impersonal phrasing for system states
  („Backup läuft“, not „Wir sichern gerade“). No exclamation marks, no jargon in primary UI, no raw Kopia output outside "Details".
- Buttons are verbs („Jetzt sichern“, „Wiederherstellen…“); add „…“ when the button opens further input (HIG).
- **Glossary — use exactly these terms:**

| Concept | German UI | English UI | Never say |
|---|---|---|---|
| Kopia repository | Speicherziel | Destination | Repository, Repo |
| Backup plan | Backup-Plan | Backup Plan | Job, Profil |
| Source folder | Quelle | Source | Pfad (in UI) |
| Snapshot | Backup (Zeitpunkt), in tables „Snapshot“ | Backup / Snapshot | Manifest |
| Run | Sicherung / Backup-Lauf | Backup run | Task |
| Retention | Aufbewahrung | Retention | Prune, Policy |
| Exclusions | Ausschlüsse | Exclusions | Ignore rules |
| Verify | Prüfen / Integritätsprüfung | Verify | Content verify |
| Maintenance | Wartung | Maintenance | GC |
| Agent | Hintergrunddienst | Background service | Daemon, Agent |
| Encryption password | Backup-Passwort | Backup password | Repo password |

- Error message pattern: **Title** (what happened, ≤ 6 words) · **Body** (why + consequence, 1–2 sentences) · **Action button**.
  Example: „Speicherziel nicht verfügbar“ · „Das Laufwerk „Tresor“ ist nicht angeschlossen. Das nächste Backup startet automatisch, sobald es verbunden ist.“ · [OK].

### 7.8 Design review checklist (integrated UI blocks)
- [ ] Only system components, no custom chrome/backgrounds behind glass
- [ ] Light + Dark + Increase Contrast screenshots attached to the PR (German **and** English)
- [ ] No truncation at minimum window size in German
- [ ] Keyboard-only walkthrough works; VoiceOver reads every control sensibly
- [ ] Empty, loading, error and offline/unavailable states designed and previewed
- [ ] Copy matches glossary and tone; strings are in the catalog
- [ ] Destructive actions confirmed; safe default button

---

## 8. Security & privacy checklist (every PR touching engine, IPC, secrets, processes)

- [ ] No secret reaches argv, logs, config, fixtures, events or diagnostics (grep your diff for `password`, `secret`, `token`, `key`)
- [ ] New XPC requests validate all input (IDs exist, paths sane, sizes bounded)
- [ ] Child processes: explicit environment whitelist, timeout, cancellation escalation, both pipes drained
- [ ] File writes are atomic; temp files with 0600 in a 0700 directory, deleted afterwards
- [ ] No network calls besides the user's configured destinations, the local Kopia server and the Sparkle appcast

---

## 9. Definition of Done

A substantial implementation block is complete when **all** apply; release readiness is tracked separately:
1. Behaviour matches `docs/PROJEKT.md` (or the spec was updated in the same PR with a §17 entry).
2. Tests added/updated and relevant block-boundary verification from §5 passed; lint clean and zero new compiler warnings. Pure docs do not require code rebuilds.
3. UI changes: previews and relevant automated checks exist; the integrated design checklist §7.8 is assessed, with unperformed manual audit items explicitly tracked for Phase 5/6.
4. Engine/IPC/secret changes: security checklist §8 satisfied.
5. User-visible strings localized (DE + EN).
6. Compact `docs/STATUS.md` and `docs/IMPLEMENTIERUNG.md` updated; changed architecture/plan reflected in PROJEKT.md.
7. You actually ran/verified it. Report honestly what you did **not** verify.

## 10. Don'ts

- Don't add dependencies, entitlements, build phases or background modes without asking and logging.
- Don't commit build products, `Vendor/` binaries, `.xcuserdata`, secrets, real repository data or personal paths.
- Don't touch the user's real Kopia config or the `/Volumes/TRESOR` repository on the development machine; use temp repos.
- Don't "fix" failing tests by weakening assertions or deleting them; don't disable strict concurrency to silence errors.
- Don't use deprecated APIs (`ObservableObject`, `NavigationView`, `onChange(of:perform:)` single-arg, `SMLoginItemSetEnabled`,
  `NSUserNotification`, `Process.launch()`); use the modern equivalents.
