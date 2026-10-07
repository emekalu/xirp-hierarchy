# xirp-hierarchy

An [Agent Skill](https://agentskills.io/specification) that turns [xirp](https://github.com) sessions into a **lead / worker hierarchy**.

The first session becomes the **lead**. It writes a charter (conventions, test command, deploy rules), spawns **worker** sessions in isolated git worktrees, receives their reports, reviews and tests each branch itself, and is the only session allowed to integrate and deploy. Workers implement one scoped task each and report back; they never merge or deploy.

Works identically in **pi**, **Claude Code**, and **Codex** — all three read the same `SKILL.md`.

## Install

```bash
git clone https://github.com/emekalu/xirp-hierarchy ~/code/xirp-hierarchy
cd ~/code/xirp-hierarchy
./install.sh            # links into ~/.pi/skills, ~/.claude/skills, ~/.codex/skills
./install.sh claude     # or just one harness
./install.sh --uninstall
```

Requirements: `xirp` at `~/.local/bin/xirp` (installed by the Chirp desktop app), `jq`, `git`, and `sqlite3` (preinstalled on macOS). Works with bash 3.2+.

**When not to use it:** coordination (briefing, context loading, review, integration) has real cost. Use a hierarchy only for 2–3 substantial tasks with disjoint files, clear interfaces, and a runnable test command. Otherwise use one session.

## Use

In the session that should lead:

```
/skill:xirp-hierarchy            # pi — Claude Code and Codex pick it up by description
```

Then the lead will:

1. `init --test-cmd "npm test"`: write the charter (limits default to 3 workers, 120 min, $10 per worker), then `ctx add --kind interface|decision ...` to record shared interfaces before spawning.
2. `spawn --name api --owns src/api --goal "…" [--after <worker>]` — overlapping ownership and over-limit spawns are refused. Then `preflight` to confirm every worker actually started.
3. `wait` (repeat) — blocks until a worker needs you; `status` / `inbox` / `tell [--fyi]` / `broadcast [--fyi]`. Flags: `STALE_ACCEPTANCE`, `UNVERIFIED`, `DIRTY`, `OVER_TIME`, `OVER_COST`, `STALLED`, `WAITING:*`.
4. `review <w>` → `verify <w>` (lead runs the tests) → `accept <w>` (pinned to the commit SHA) or `reject <w> "…"`.
5. `integrate` (merges accepted SHAs, runs tests) → `deploy-check` → deploy (asks you first) → `finish --cleanup`.

Workers call `scripts/hierarchy.sh report READY|QUESTION|BLOCKED|PROGRESS "…"`; `READY` is refused with uncommitted changes.

## How the hierarchy is enforced

| Concern | Mechanism |
|---|---|
| One source of truth | `~/.local/state/xirp-hierarchy/<lead-id>/charter.md`, outside any worktree, read by every session by absolute path |
| Reporting line | workers are created with `--parent <lead>` and tagged `role:worker lead:<id>`; reports go through `xirp session message` |
| Sequencing | `spawn --after <worker>` adds an `xirp --depends-on` edge |
| Reliable state | SQLite (WAL) per hierarchy; multi-step writes are `BEGIN IMMEDIATE` transactions, with schema constraints |
| Shared context | lead-curated decisions/interfaces/gotchas with FTS5 search; worker entries are proposals until approved; approved entries render into the charter |
| File ownership | `spawn --owns`; overlaps refused unless sequenced with `--after`; `accept` rejects out-of-scope diffs |
| Verifiable acceptance | `verify` records SHA, command, exit code, log; `accept` requires a clean tree and a passing run at HEAD; any new commit makes it stale |
| Integration | merges the accepted SHA (not the branch tip), aborts on conflict, re-runs tests; `deploy-check` gates deploy |
| Safe completion | `finish` refuses with unintegrated work; worktrees with tracked changes and unmerged branches are never deleted; untracked-only worktrees need `--discard-untracked` |
| Stall detection | `preflight` after spawning fails if a worker hasn't started and shows its terminal tail; `status` flags `STALLED` (no tokens after 3+ min) |
| Low-noise monitoring | `wait` blocks until something needs the lead (report, proposal, state or flag change) with a persistent read cursor; `[LEAD FYI]` messages and an acknowledgement filter stop workers from replying just to acknowledge |
| Bounded coordination | max workers, minutes and cost per worker, enforced at spawn and flagged in `status` |
| Deployment | lead only; charter defaults to `Pre-authorised by user: no` |

## Layout

```
skills/xirp-hierarchy/
├── SKILL.md                     # instructions loaded by the agent
├── scripts/hierarchy.sh         # entry point; `help` lists commands
├── scripts/lib/                 # common (SQLite state), lead, review, integrate, worker, context
├── assets/charter-template.md   # filled in by `init`
├── assets/worker-brief.md       # prepended to every worker's goal
└── references/
    ├── lead-protocol.md
    └── worker-protocol.md
install.sh
tests/run.sh                     # 98 checks against a mock xirp + real git repo
```

## Test

```bash
tests/run.sh            # bash 5
tests/run.sh /bin/bash  # macOS bash 3.2
```

## License

MIT

## Tested live

Besides the mock suite, a two-worker run against real xirp/Claude Code sessions ran end to end: spawn → worker interface proposals → lead approval → READY → verify → accept → integrate (27 tests on the merged result) → deploy-check → cleanup. It took about 14 minutes and $1.50. Bugs it surfaced (workers created in the wrong project, test artefacts blocking gates, undetected stalls) are fixed and covered by tests.
