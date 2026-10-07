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

Requirements: `xirp` at `~/.local/bin/xirp` (installed by the Chirp desktop app), `jq`, `git`.

## Use

In the session that should lead:

```
/skill:xirp-hierarchy            # pi — Claude Code and Codex pick it up by description
```

Then the lead will:

1. `scripts/hierarchy.sh init` — write the charter and fill it from the repo with you.
2. `scripts/hierarchy.sh spawn --name "…" --goal "…" [--after <worker>]` — one worker per independent task.
3. `status` / `tell` / `broadcast` — monitor and answer `[WORKER QUESTION]` reports.
4. `review <worker>` → run the charter's tests in the worker's worktree → `accept` or `tell` fixes.
5. Integrate in charter order, run the full suite, deploy (asks you first unless pre-authorised), `finish [--cleanup]`.

Workers call `scripts/hierarchy.sh report READY|QUESTION|BLOCKED "…"` to talk to the lead.

## How the hierarchy is enforced

| Concern | Mechanism |
|---|---|
| One source of truth | `~/.local/state/xirp-hierarchy/<lead-id>/charter.md`, outside any worktree, read by every session by absolute path |
| Reporting line | workers are created with `--parent <lead>` and tagged `role:worker lead:<id>`; reports go through `xirp session message` |
| Sequencing | `spawn --after <worker>` adds an `xirp --depends-on` edge |
| Testing gate | the lead re-runs the charter test command in the worker's worktree before `accept`; worker claims are not trusted |
| Deployment | lead only; charter defaults to `Pre-authorised by user: no` |

## Layout

```
skills/xirp-hierarchy/
├── SKILL.md                     # instructions loaded by the agent
├── scripts/hierarchy.sh         # init | spawn | status | tell | broadcast | review | accept | report | inbox | finish
├── assets/charter-template.md   # filled in by `init`
├── assets/worker-brief.md       # prepended to every worker's goal
└── references/
    ├── lead-protocol.md
    └── worker-protocol.md
install.sh
```

## License

MIT
