---
name: xirp-hierarchy
description: 'Run a bounded lead/worker agent hierarchy over xirp sessions. The first session becomes the lead: it writes a charter, spawns 2–3 worker sessions with explicit file ownership in isolated worktrees, verifies each worker branch by running tests itself (acceptance is pinned to a commit SHA), integrates the accepted commits, and owns deployment. Use when the user wants to split work across multiple agents while one session stays in charge of consistency, testing, and deployment.'
---

# xirp-hierarchy

One session leads; a few others work. The lead plans, briefs, verifies, integrates, and deploys. Workers implement one scoped task in their own worktree and report back. They never merge or deploy.

Helper: `scripts/hierarchy.sh` (relative to this skill directory). Run `scripts/hierarchy.sh help` for the full command list. It needs `xirp`, `jq`, `git`, and `sqlite3`. It never calls `xirp update`.

Read `references/lead-protocol.md` when acting as lead and `references/worker-protocol.md` when acting as worker.

## First: is a hierarchy worth it?

Coordination costs real tokens and time: decomposition, a fresh context load per worker, review, verification, and integration. Use a hierarchy only when **all** of these hold:

- the work splits into 2–3 tasks that touch **disjoint files** (or can be strictly sequenced);
- each task is substantial (roughly 30+ minutes of agent work), not a one-file tweak;
- interfaces between tasks are clear enough to write down before workers start;
- there is a runnable test command that meaningfully checks each task.

If any fails, tell the user and do the work in a single session. Start with 2 workers; the default cap is 3.

## Which role am I?

```bash
scripts/hierarchy.sh whoami     # lead <id> | worker <id> (lead: <id>) | none
```

## Lead workflow

1. **Initialise** (first session only):
   ```bash
   scripts/hierarchy.sh init --test-cmd "npm test" [--max-workers 3 --max-minutes 120 --max-cost 10]
   ```
   Fill `charter.md` from the repo (lint config, CI, CONTRIBUTING, existing patterns). Ask the user only what the repo cannot answer. The test command stored in `state.db` is the one actually executed; change it with `config --test-cmd`. The charter's test command, limits, Tasks, and Shared context sections are generated from `state.db`; don't edit them by hand.

   Record interfaces and key decisions **before spawning**, so every brief points at the same answers:
   ```bash
   scripts/hierarchy.sh ctx add --kind interface --key api/users "GET /users/:id -> {id,name,email}; 404 problem+json"
   scripts/hierarchy.sh ctx add --kind decision  --key errors    "RFC7807 problem+json everywhere"
   ```

2. **Spawn workers with explicit ownership:**
   ```bash
   scripts/hierarchy.sh spawn --name api --owns src/api,tests/api --goal "..."
   scripts/hierarchy.sh spawn --name client --owns src/client --after api --goal "..."
   ```
   `spawn` refuses if the owned paths overlap another active worker (unless sequenced with `--after` that worker) or if the worker cap is reached. Each worker gets the brief, `--parent <lead>`, and its own branch and worktree.

3. **Monitor:** `status` shows session state, HEAD, elapsed minutes, cost, and flags (`STALE_ACCEPTANCE`, `DIRTY`, `UNVERIFIED`, `OVER_TIME`, `OVER_COST`). `inbox` lists reports. Answer questions with `tell`; act on `OVER_*` with `tell` or `cancel`.

4. **Review gate**, per worker after a `READY` report:
   ```bash
   scripts/hierarchy.sh review api     # commits, diff stat, scope check, last verification
   scripts/hierarchy.sh verify api     # lead runs the test command in the worker's worktree
   scripts/hierarchy.sh accept api --note "..."   |   reject api "what to fix"
   ```
   `accept` refuses unless the tree is clean, the latest verification passed at the current HEAD with the current test command, and all changes are within the owned paths. Override the scope check only with `--allow-out-of-scope "reason"`. Acceptance records the SHA; any later commit marks it stale and blocks integration.

5. **Integrate and deploy (lead only)**, from the lead checkout on the base branch:
   ```bash
   scripts/hierarchy.sh integrate [--dry-run]    # merges each *accepted SHA*, then runs tests
   scripts/hierarchy.sh deploy-check             # all tasks integrated + tests passed at HEAD
   ```
   Then follow the charter's Deployment section. Ask the user before deploying unless the charter says `Pre-authorised by user: yes`.

6. **Finish:**
   ```bash
   scripts/hierarchy.sh finish --cleanup [--delete-branches]
   ```
   Refuses if any task is unintegrated or a branch has commits missing from the base branch. `--force` overrides that, but worktrees with uncommitted changes are never deleted and unmerged branches are never deleted.

## Worker workflow

If `whoami` says `worker`, follow `references/worker-protocol.md`. In short: read the charter, change only your owned paths, commit, run the test command, then report:

```bash
scripts/hierarchy.sh report READY "what changed; test result"     # refused if uncommitted changes
scripts/hierarchy.sh report QUESTION "..."  |  report BLOCKED "..."  |  report PROGRESS "..."
```

After `READY`, stop and wait. Any new commit invalidates an acceptance.

## Harness notes

The skill is identical for pi, Claude Code, and Codex.

- **pi**: `/skill:xirp-hierarchy`; path `~/.pi/skills/xirp-hierarchy`.
- **Claude Code**: path `~/.claude/skills/xirp-hierarchy`; run the helper with the Bash tool. Only pass `--harness claude --auto-mode` to `spawn` if the user asks for unattended workers.
- **Codex**: path `~/.codex/skills/xirp-hierarchy`. If a command fails with `Could not connect to Chirp daemon`, retry it with local network approval. Do not switch edition or daemon.

Workers may run on a different harness than the lead; reporting uses only `xirp session message` and the shared state file.

## Invariants

- State: `~/.local/state/xirp-hierarchy/<lead-id>/` (`state.db`, `charter.md`, `logs/`). `state.db` is SQLite in WAL mode; multi-step writes are transactions. `dump` prints it as JSON. Never edit it by hand.

## Shared context pool

A lead-curated store of decisions, interfaces, gotchas, and findings, in `state.db` with full-text search.

- **Lead** `ctx add` → approved immediately; re-using a key supersedes the old entry. Add `--broadcast` when running workers must react now.
- **Worker** `ctx add` → `proposed`; the lead gets a `[WORKER PROPOSAL]` message and runs `ctx approve <id>` or `ctx reject <id> "why"`. Proposals are not binding and are excluded from search and the charter.
- Approved entries are rendered into the charter's **Shared context** section, so workers get them by reading the charter. `ctx search "words"` (max 20 results, default 5) is for targeted lookups.
- Keep entries short (2000-character cap). Point to files instead of pasting code. It is not a chat channel: questions still go through `report QUESTION`.
- Answering a worker question that affects others? Answer with `tell`, then `ctx add --kind decision` so the answer is binding for everyone.
- `--parent` is the reporting edge; `--after` / `--depends-on` is the sequencing edge.
- A worker's claim that tests pass is not evidence; only `verify` records are.
- If a session stalls at a harness trust prompt, follow the `xirp` skill and ask the user before accepting trust.
