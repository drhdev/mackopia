# CLAUDE.md

All shared project rules live in AGENTS.md (also used by Codex). Read and follow it completely:

@AGENTS.md

Spec and progress (read the relevant parts before each task):

- @docs/STATUS.md
- `docs/PROJEKT.md` — full specification (German); read the section for your current phase, not the whole file every time.

---

## Claude Code–specific notes

- **Start of a session:** read `docs/STATUS.md`, check `git status` and the current branch, then claim your task in STATUS.md
  before editing code (AGENTS.md §5). Use branch prefix `claude/`.
- **Plan before larger changes:** for anything spanning more than one module or ~150 lines, use plan mode first and
  point out which PROJEKT.md sections the plan implements.
- **Subagents:** use them for broad read-only searches or independent review of a finished PR; keep design decisions in the main session.
- **Verification:** after UI changes, build and launch the app and look at it (screenshots in light and dark mode) before
  reporting done. After engine changes, run the integration tests, not just unit tests.
- **Never** run destructive Kopia commands against anything except temp repositories created by tests.
- **Memory:** store only non-obvious, durable insights (e.g. a Kopia quirk) in memory *and* write them into the repo
  (`docs/PROJEKT.md` §17 or a code comment) so Codex gets them too. The repo is the shared memory; your private memory is not.
- When the user writes German, answer in German; code, comments and commits stay English.
