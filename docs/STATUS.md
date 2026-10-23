# Status & Hand-off

Shared progress log for all agents and humans. Update at the end of every work session (AGENTS.md §5).

## Current phase

**Phase 0 – Fundament & Spikes** (see `docs/PROJEKT.md` §14) — not started.

## In progress

| Task | Agent / person | Branch | Modules / files touched | Started |
|---|---|---|---|---|
| — | | | | |

## Done

| Date | Task | PR / commit | Notes |
|---|---|---|---|
| 2026-10-23 | Spec `docs/PROJEKT.md`, `AGENTS.md`, `CLAUDE.md`, repo bootstrap | initial commit | — |

## Next up (Phase 0)

1. Xcode project (App + Agent targets), local package `MacKopiaKit` with empty module targets, xcconfigs, entitlements, String Catalog, `.swift-format`, CI skeleton.
2. `Scripts/fetch-kopia.sh` (pinned 0.23.1, SHA256-verified, universal, signed) + build phase.
3. Spikes A–E (server handshake, cancel semantics, TCC/FDA, secrets via env, metadata) → results into PROJEKT.md §17, fixtures into the repo.

## Open questions for the user

- Final app name, bundle-ID prefix, Apple Developer Team ID (PROJEKT.md §16).
- License model of the app.

## Gotchas found

- Dev machine has a pre-existing Kopia default config pointing to `/Volumes/TRESOR`. Never use or modify it (PROJEKT.md Anhang A).
