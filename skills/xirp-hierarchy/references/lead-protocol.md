# Lead protocol

The lead is the only session that merges, deploys, or changes shared conventions. Its job is to keep N workers producing code that looks like one person wrote it.

## Before spawning

1. Run `scripts/hierarchy.sh init` once. Never init twice for the same session; `whoami` will tell you if a charter already exists.
2. Fill the charter **from the repository**, not from memory: lint/format config, test runner in `package.json`/`Makefile`/`pyproject.toml`, CI workflow files, `CONTRIBUTING.md`, existing code patterns. Only ask the user what the repo cannot answer.
3. Decide the split so that workers do not edit the same files. Prefer fewer, larger, independent tasks over many small overlapping ones. If overlap is unavoidable, chain with `--after`.
4. Record every task in the charter's task table before spawning it. `spawn` also appends to `tasks.json`, but the charter table is what workers read.

## While workers run

- Treat `[WORKER QUESTION]` as the highest priority: a blocked worker burns tokens idling. Answer with `tell`, and append the decision to the charter's *Decisions log* so later workers get the same answer.
- When a worker reports `READY`, review promptly. Do not let accepted-but-unreviewed branches pile up; integration conflicts grow with time.
- If you change the charter mid-run (new convention, changed test command), `broadcast` the change and point at the charter section.
- Do not write feature code in the lead session while workers are running on the same area. The lead's checkout is for integration and verification only.

## Review checklist (per worker)

Run `scripts/hierarchy.sh review <worker>`. Then:

- [ ] Diff stays inside the scope recorded for that task.
- [ ] Conventions in the charter are followed (format, naming, error handling, logging).
- [ ] Tests exist for new behaviour and match the charter's minimum expectation.
- [ ] Run the charter's test command **yourself** in the printed worktree path. The worker's pasted output is a claim, not evidence.
- [ ] No deploy/CI/infra/secret changes. No edits to shared interfaces that other tasks depend on unless the charter planned it.
- [ ] Commit messages follow the charter style.

Outcome:
- Pass → `scripts/hierarchy.sh accept <worker>`.
- Fail → `scripts/hierarchy.sh tell <worker> "..."` with concrete, file-level instructions. Wait for a fresh `READY`.

## Integration

1. All tasks accepted → integrate in the charter's *Integration order* in the lead's own checkout (the project root or the lead's worktree). Prefer `git merge --no-ff <branch>` so each task stays visible in history, unless the charter says otherwise.
2. Run the full test command on the integrated result.
3. Only then follow the *Deployment* section. If `Pre-authorised by user` is not `yes`, ask the user with a one-line summary of what will be deployed and the exact command.
4. `scripts/hierarchy.sh finish [--cleanup]`. `--cleanup` stops worker sessions and deletes their worktrees (branches are kept unless you pass `--delete-branches`). Ask the user before `--cleanup` if any worker branch has not been merged.

## Failure modes to watch

- Worker session `failed`/`stopped` without a report: `xirp session get <id>` for the reason, then either `tell` it to resume or spawn a replacement with the same scope and `--branch` reusing the branch name.
- Worker stalls at a harness trust prompt: see the `xirp` skill — ask the user before accepting trust.
- Two workers touching the same file: stop one (`tell` it to pause), finish and accept the other, then `tell` the first to rebase onto the accepted branch.
