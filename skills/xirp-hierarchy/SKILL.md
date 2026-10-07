---
name: xirp-hierarchy
description: 'Run a lead/worker agent hierarchy over xirp sessions. The first session becomes the lead: it writes a charter (conventions, test and deploy rules), spawns worker sessions in isolated worktrees, receives their reports, reviews and tests their branches, and owns integration and deployment. Use when the user wants to split work across multiple agents while keeping one session in charge of consistency, testing, and deployment.'
---

# xirp-hierarchy

One session leads; others work. The lead never writes feature code in parallel with workers — it plans, briefs, reviews, tests, integrates, and deploys. Workers never merge or deploy — they implement in their own worktree and report back.

Helper script: `scripts/hierarchy.sh` (relative to this skill directory). Run `scripts/hierarchy.sh help` for usage. It wraps `xirp` and `jq`; it never calls `xirp update`.

Read `references/lead-protocol.md` when acting as lead. Read `references/worker-protocol.md` when acting as worker (the worker brief also points there).

## Which role am I?

```bash
scripts/hierarchy.sh whoami
```

- `lead` — this session (`$CHIRP_SESSION_ID`) has a charter under `~/.local/state/xirp-hierarchy/<id>/`.
- `worker` — this session's `parentSessionId` is a lead, or its goal contains `XIRP-HIERARCHY WORKER BRIEF`.
- `none` — no hierarchy yet. If the user asks for one, this session becomes the lead.

Outside a managed session (`$CHIRP_SESSION_ID` unset) you can still run the lead workflow by passing `--lead <session-id>`, but prefer running it from inside the lead session so messages route correctly.

## Lead workflow

### 1. Initialise (first session only)

```bash
scripts/hierarchy.sh init
```

This tags the current session `role:lead` and writes `charter.md` from `assets/charter-template.md`. Then **edit the charter** with the user before spawning anyone. The charter is the single source of truth for:

- coding conventions, file layout, naming
- the exact test command(s) a worker must pass before reporting
- the integration branch and whether workers may push
- what is forbidden for workers (deploy, merge, touch CI/infra, change shared interfaces without asking)

Ask the user concise questions only for things the repo does not already answer (e.g. look for `package.json` scripts, `Makefile`, CI config, `CONTRIBUTING.md` first).

### 2. Plan the split

Break the goal into worker tasks that are **independent in files touched**. Record them in the charter's task table. If two tasks must touch the same file, sequence them with `--after` (dependency edge) rather than running them in parallel.

### 3. Spawn workers

```bash
scripts/hierarchy.sh spawn --name "auth: add refresh tokens" \
  --branch jd/auth-refresh \
  --goal "Implement refresh-token rotation in src/auth. Add unit tests in tests/auth."

# sequenced worker: queues until the named worker/session finishes
scripts/hierarchy.sh spawn --name "auth: wire refresh into client" \
  --after jd/auth-refresh --goal "..."
```

`spawn` prepends the worker brief (`assets/worker-brief.md`, with the charter path and lead id substituted), sets `--parent` to the lead so messages route back, tags `role:worker lead:<id>`, and creates an isolated worktree from the charter's base branch. Do not add `--harness`/`--model` unless the user asked.

### 4. Monitor and respond

```bash
scripts/hierarchy.sh status          # table of workers: status, branch, last message
scripts/hierarchy.sh inbox           # reports workers sent to the lead (from the lead's transcript)
scripts/hierarchy.sh tell <worker> "message"   # answer a question / redirect a worker
scripts/hierarchy.sh broadcast "message"       # same to all running workers
```

Workers report with a fixed header (`[WORKER REPORT]`, `[WORKER QUESTION]`, `[WORKER BLOCKED]`). When one arrives in this session's transcript, act on it: answer questions quickly, and start a review when a report says `READY`.

### 5. Review and test each worker branch

```bash
scripts/hierarchy.sh review <worker>
```

This prints the branch diff against the base branch and the worktree path. Then, as lead:

1. Read the diff for charter compliance (conventions, scope, tests present).
2. Run the charter's test command **in the worker's worktree** (path is printed). Do not trust the worker's claim.
3. Either `tell <worker>` what to fix and wait for a new report, or mark it accepted:
   ```bash
   scripts/hierarchy.sh accept <worker>
   ```

### 6. Integrate and deploy (lead only)

Once all tasks are accepted, integrate in the lead's own checkout in the order recorded in the charter, run the full test suite once more on the integrated result, then follow the charter's deploy procedure. Ask the user before any deploy that is not explicitly pre-authorised in the charter.

```bash
scripts/hierarchy.sh finish        # marks hierarchy done; optionally stops/deletes workers with --cleanup
```

## Worker workflow

If `whoami` says `worker`, follow `references/worker-protocol.md`: read the charter at the path given in your brief, stay inside your assigned scope, run the charter's test command before reporting, and report to the lead with:

```bash
scripts/hierarchy.sh report READY "summary of what changed and test results"
scripts/hierarchy.sh report QUESTION "what you need decided"
scripts/hierarchy.sh report BLOCKED "what is blocking you"
```

Never merge, push to the integration branch, deploy, or change files outside your scope without a `QUESTION` → answer first.

## Harness notes

The skill is identical for pi, Claude Code, and Codex; only invocation differs.

- **pi** — force-load with `/skill:xirp-hierarchy`. Skill path: `~/.pi/skills/xirp-hierarchy`.
- **Claude Code** — skill path: `~/.claude/skills/xirp-hierarchy`. Run the helper with the Bash tool. If you want workers on Claude too, spawn with the default harness (the user's xirp default); only pass `--harness claude --auto-mode` if the user asks for unattended workers.
- **Codex** — skill path: `~/.codex/skills/xirp-hierarchy`. The command sandbox may block the local daemon: if a helper command fails with `Could not connect to Chirp daemon`, retry that same command with local network approval. Do not switch edition or daemon as a workaround.

Workers may run on a different harness than the lead; the reporting protocol is harness-agnostic because it only uses `xirp session message`.

## Rules that hold for both roles

- All `xirp` calls use `~/.local/bin/xirp`; if it is missing say so rather than guessing at commands. Verify unusual commands with `xirp skill` first.
- Hierarchy state lives in `~/.local/state/xirp-hierarchy/<lead-id>/` (`charter.md`, `tasks.json`). It is outside any worktree so every session can read it by absolute path.
- The dependency edge (`--depends-on` / `--stack-parent`) is for *sequencing*; the messaging edge (`--parent`) is for *reporting*. Workers always get the messaging edge to the lead; they get a dependency edge only when `--after` is used.
- If a worker session stalls at a harness trust prompt, follow the `xirp` skill's guidance and ask the user before accepting trust.
