# Lead protocol

The lead is the only session that merges, deploys, or changes shared conventions. Its job is to keep a few workers producing code that looks like one person wrote it, and to make every "done" claim verifiable.

## Before spawning

1. Apply the go/no-go test in `SKILL.md`. If the work does not split into 2–3 disjoint, substantial tasks with a real test command, do it in one session.
2. `init --test-cmd "..."` once. Fill the charter **from the repository**: lint/format config, the test runner in `package.json`/`Makefile`/`pyproject.toml`, CI workflows, `CONTRIBUTING.md`, existing patterns.
3. Write down the interfaces between tasks in the charter before spawning, such as function signatures, API shapes, and file boundaries. Most integration failures come from interfaces left implicit.
4. Assign **ownership** per task (`--owns`). Keep it narrow. If two tasks must touch the same file, sequence them with `--after`; never run them in parallel.
5. Record every task in the charter's task table. `tasks.json` is the machine record; the charter is what workers read.

## While workers run

- `[WORKER QUESTION]` first: a blocked worker burns time idling. Answer with `tell`, and append the decision to the charter's Decisions log.
- Check `status` regularly. React to flags:
  - `OVER_TIME` / `OVER_COST`: ask for a status `report`, narrow the task, or `cancel` it. Do not raise limits silently; tell the user.
  - `UNVERIFIED`: the worker reported READY; run `review` + `verify`.
  - `STALE_ACCEPTANCE`: the worker committed after acceptance; `verify` + `accept` again, or `reject`.
- Do not write feature code in the lead checkout while workers run. It is for integration and verification only.
- If you change the charter mid-run, `broadcast` the change.

## Review gate (per worker)

```bash
scripts/hierarchy.sh review <w>
scripts/hierarchy.sh verify <w>
scripts/hierarchy.sh accept <w> --note "..."      # or: reject <w> "concrete, file-level fixes"
```

Before `accept`, read the diff yourself:

- [ ] Conventions in the charter are followed (format, naming, error handling, logging, commit style).
- [ ] Tests exist for new behaviour at the charter's minimum.
- [ ] Interfaces match what the charter specified.
- [ ] No CI/infra/secret/dependency changes the charter didn't allow.

`accept` mechanically enforces: clean tree, branch ahead of base, latest verification at current HEAD passed with the current test command and was not disturbed mid-run, and all files within owned paths (override only with `--allow-out-of-scope "reason"`, which is recorded).

## Integration and deployment

1. On the base branch in the lead checkout with a clean tree: `integrate --dry-run`, then `integrate`. It merges each task's **accepted SHA** (not the branch tip) with `--no-ff`, in creation order (or `--order a,b`), refuses stale acceptances, aborts cleanly on conflict, then runs the test command on the integrated HEAD and records the result.
2. On conflict: `tell` the worker to rebase onto the base branch, then `verify` + `accept` again.
3. `deploy-check` must pass: every non-cancelled task integrated, tree clean, and a passing integration run at the current HEAD.
4. Follow the charter's Deployment section. Unless it says `Pre-authorised by user: yes`, ask the user with the HEAD SHA and exact command first.

## Completion

`finish [--cleanup] [--delete-branches]`:

- refuses (without `--force`) if any task is not integrated/cancelled or any worker branch has commits not in the base branch;
- never deletes a worktree with uncommitted changes, even with `--force`;
- deletes a branch only if it is fully merged.

Ask the user before `--force`.

## Failure modes

- Worker `failed`/`stopped` without a report: check `xirp session get <id>`. Either `tell` it to continue or `cancel` and spawn a replacement with the same `--owns`.
- Spawn printed "created but NOT tracked": stop and fix before continuing; the session exists outside the hierarchy.
- Harness trust prompt: see the `xirp` skill; ask the user before accepting.
