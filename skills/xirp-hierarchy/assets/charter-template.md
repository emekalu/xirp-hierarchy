# Hierarchy charter

Lead session: `{{LEAD_ID}}`
Project: `{{PROJECT}}`
Base branch: `{{BASE_BRANCH}}`
Integration branch: `{{BASE_BRANCH}}` (lead integrates here; workers never push to it)
Created: {{CREATED_AT}}

## Objective

<!-- One paragraph: what the whole hierarchy is delivering. -->

## Conventions

<!-- Fill from the repo first (lint config, CONTRIBUTING, existing patterns). Keep it concrete. -->
- Language / framework:
- Formatting / lint command:
- Naming:
- Error handling:
- Logging:
- Commit message style:

## Testing

- Required test command (executed by `verify` and `integrate`; change with `hierarchy.sh config --test-cmd`):
  <!-- BEGIN GENERATED: testcmd -->
<!-- END GENERATED: testcmd -->
- Minimum expectation for new code: <!-- e.g. unit tests for every new public function -->
- Lead runs this in each worker worktree (`verify`) before `accept`; acceptance is pinned to that commit SHA.
- `integrate` runs it again on the merged result; `deploy-check` requires that run to pass at HEAD.

## Deployment

- Who deploys: **lead only**
- Procedure:
  ```bash
  # e.g. gh pr create ... ; ./scripts/deploy.sh staging
  ```
- Gate: `hierarchy.sh deploy-check` must pass first.
- Pre-authorised by user: `no`  <!-- change to `yes` only if the user explicitly says so -->
- Rollback:

## Limits

<!-- BEGIN GENERATED: limits -->
<!-- END GENERATED: limits -->

## Worker rules

1. Work only in your own worktree and only in your owned paths (`--owns`). `accept` rejects out-of-scope changes.
2. Do not merge, rebase onto, or push to the integration branch. Commit on your own branch.
3. Do not deploy, change CI, infra, secrets, or shared interfaces. Ask with `[WORKER QUESTION]` first.
4. Commit everything and run the required test command before every `READY` report. After READY, stop: new commits invalidate acceptance.
5. Report to the lead using `scripts/hierarchy.sh report`. Do not message other workers directly.
   Propose shared knowledge with `scripts/hierarchy.sh ctx add`; it becomes binding only when the lead approves it.
6. If a dependency on another worker's output blocks you, report `BLOCKED` and wait.

## Tasks

<!-- BEGIN GENERATED: tasks (from state.db; do not edit) -->
<!-- END GENERATED: tasks -->

## Integration order

<!-- Default: spawn order. Override with `integrate --order a,b`. Accepted SHAs are merged, not branch tips. -->

## Shared context

Approved decisions, interfaces, and gotchas. These are binding for every worker.
Lead: `hierarchy.sh ctx add --kind interface --key auth/token "..."`. Workers propose the same way; search with `ctx search "..."`.

<!-- BEGIN GENERATED: context (from state.db; do not edit) -->
<!-- END GENERATED: context -->
