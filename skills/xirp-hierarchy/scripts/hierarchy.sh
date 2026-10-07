#!/usr/bin/env bash
# hierarchy.sh — lead/worker orchestration over xirp sessions.
#
# State lives in $STATE_ROOT/<lead-id>/:
#   state.db     SQLite (WAL): hierarchy, tasks, reports, verifications, reviews,
#                invalidations, integration runs, shared context (+ FTS5 index)
#   charter.md   human-readable rules; Tasks and Shared context sections are generated
#   logs/        verification and integration test logs
#
# Multi-statement writes run in BEGIN IMMEDIATE transactions; concurrent sessions
# serialise on SQLite's lock. Compatible with bash 3.2 (macOS /bin/bash).
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SELF")"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
XIRP="${XIRP_BIN:-$HOME/.local/bin/xirp}"
STATE_ROOT="${XIRP_HIERARCHY_STATE:-$HOME/.local/state/xirp-hierarchy}"
LEAD="${LEAD:-}"

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/lead.sh"
. "$SCRIPT_DIR/lib/review.sh"
. "$SCRIPT_DIR/lib/integrate.sh"
. "$SCRIPT_DIR/lib/worker.sh"
. "$SCRIPT_DIR/lib/context.sh"

cmd_help() {
  cat <<EOF
hierarchy.sh — lead/worker orchestration over xirp sessions

Lead (run inside the lead session, or pass --lead <id>):
  init [--test-cmd C] [--base-branch B] [--max-workers 3] [--max-minutes 120] [--max-cost 10]
  config [--test-cmd C] [--max-workers N] [--max-minutes M] [--max-cost USD]
  spawn --name N --goal G --owns path[,path] [--branch B] [--after W] [--force]
  status [--json]                    workers, HEAD, time, cost, flags (STALE_ACCEPTANCE, DIRTY, UNVERIFIED, OVER_*)
  inbox [--all]                      worker reports
  tell <worker> "msg" | broadcast "msg"
  review <worker>                    commits, diff stat, scope check, last verification
  verify <worker>                    run the test command in the worker worktree; records sha+exit+log
  accept <worker> [--note T] [--allow-out-of-scope REASON]
                                     requires: clean tree, passing verification at current HEAD, in-scope diff
  reject <worker> "what to fix"
  cancel <worker> [reason]           stop the session; keeps worktree/branch
  integrate [--repo P] [--dry-run] [--order a,b]
                                     merge each accepted SHA (not branch tip) into the base branch, then run tests
  deploy-check [--repo P]            pass only if every task is integrated and tests passed at current HEAD
  finish [--cleanup] [--delete-branches] [--discard-untracked] [--force]
                                     refuses on uncommitted or unintegrated work unless --force (dirty is never deleted)
  charter                            print charter path
  dump                               whole state as JSON (read-only)

Shared context (lead entries are approved; worker entries are proposals until approved):
  ctx add --kind decision|interface|gotcha|finding|note --key K "body" [--task W] [--broadcast]
  ctx approve <id> [note] | ctx reject <id> [note]        lead only
  ctx search "words" [--limit 5] [--include-proposed]       approved entries, ranked
  ctx get <key|#id> | ctx list [--proposed|--all] [--kind K] | ctx render

Worker (inside a worker session):
  report READY|QUESTION|BLOCKED|PROGRESS "text"

Either:
  whoami                             lead | worker | none

State: $STATE_ROOT/<lead-id>/{state.db,charter.md,logs/}
EOF
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  whoami|init|config|spawn|status|inbox|tell|broadcast|review|verify|accept|reject|cancel|integrate|finish|charter|report|ctx|dump|help)
    "cmd_$cmd" "$@";;
  deploy-check) cmd_deploy_check "$@";;
  *) die "unknown command '$cmd' (see help)";;
esac
