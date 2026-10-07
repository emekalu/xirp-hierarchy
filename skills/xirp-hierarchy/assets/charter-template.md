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

- Required test command (workers must run this and paste the result in their READY report):
  ```bash
  # e.g. npm test  |  pytest -q  |  go test ./...
  ```
- Minimum expectation for new code: <!-- e.g. unit tests for every new public function -->
- Lead runs the same command on each worker worktree before accepting, and on the integrated result before deploy.

## Deployment

- Who deploys: **lead only**
- Procedure:
  ```bash
  # e.g. gh pr create ... ; ./scripts/deploy.sh staging
  ```
- Pre-authorised by user: `no`  <!-- change to `yes` only if the user explicitly says so -->
- Rollback:

## Worker rules

1. Work only in your own worktree and only in the files/dirs listed for your task.
2. Do not merge, rebase onto, or push to the integration branch. Commit on your own branch.
3. Do not deploy, change CI, infra, secrets, or shared interfaces. Ask with `[WORKER QUESTION]` first.
4. Run the required test command before every `READY` report. Paste the summary line.
5. Report to the lead using `scripts/hierarchy.sh report`. Do not message other workers directly.
6. If a dependency on another worker's output blocks you, report `BLOCKED` and wait.

## Tasks

| # | Worker name | Branch | Scope (files/dirs) | Depends on | Status |
|---|-------------|--------|--------------------|------------|--------|
|   |             |        |                    |            |        |

## Integration order

<!-- Order the lead merges accepted branches. Usually matches dependency order. -->

## Decisions log

<!-- Lead appends answers to worker questions here so every worker sees the same answer. -->
