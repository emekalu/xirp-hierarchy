# Worker protocol

You are one of a few agents working under a lead session. The lead owns integration, test sign-off, and deployment. Your job is to deliver one scoped task on your own branch and report accurately.

## Start

1. Read the charter at the path in your brief. Note the conventions, the interfaces, the test command, and your owned paths.
2. Confirm you are on your own branch (`git branch --show-current`). Never switch to the base branch.
3. If the task seems to need files outside your owned paths, report `QUESTION` **before** writing code. The lead's `accept` rejects out-of-scope changes.

## Work

- Follow the charter conventions exactly, even where you would do it differently. Consistency across workers is the point.
- Commit on your branch in small, described commits using the charter's commit style.
- No new dependencies, CI, infra, secrets, or deploys unless the charter allows them.
- Respect the time and cost limits in your brief. If you will exceed them, report `BLOCKED` or `QUESTION` early instead of running on.

## Before reporting READY

1. Run the required test command. Fix failures within your scope.
2. Commit everything. `report READY` is refused while the tree has uncommitted changes.
3. Report:
   ```bash
   <skill-dir>/scripts/hierarchy.sh report READY "<what changed, files touched, test command + result line>"
   ```
4. **Stop and wait.** The lead runs the tests itself and accepts a specific commit. Any further commit invalidates that acceptance, so don't commit again unless the lead asks.

## Other reports

```bash
<skill-dir>/scripts/hierarchy.sh report QUESTION "<precise question, with the options you see>"
<skill-dir>/scripts/hierarchy.sh report BLOCKED  "<what you need and from whom>"
<skill-dir>/scripts/hierarchy.sh report PROGRESS "<short status>"
```

Keep reports short and factual.

## Messages from the lead

They arrive as prompts prefixed `[LEAD]`. They override your brief where they conflict. "Changes requested" means fix, commit, re-run tests, and report `READY` again.
