# shellcheck shell=bash
# Review gate: review, verify, accept, reject, cancel.
# Acceptance is bound to a commit SHA; any new commit invalidates it.

cmd_review() {
  if [[ "${1:-}" == "--lead" ]]; then LEAD="$2"; shift 2; fi
  [[ -n "${1:-}" ]] || die "usage: review <worker>"
  LEAD="$(resolve_lead "$LEAD")"; require_lead "run this command"
  local id t wt base facts b v
  id="$(resolve_worker "$1")"; t="$(task_json "$id")"
  wt="$(worktree_of "$id")"; base="$(jq -r .base <<<"$t")"
  facts="$(wt_facts "$wt" "$base")"
  jq -e .exists <<<"$facts" >/dev/null || die "worker worktree not found (${wt:-unknown}); is the session still queued?"
  b="$(base_ref "$wt" "$base")"
  echo "worker:   $(jq -r .name <<<"$t") ($id)"
  echo "worktree: $wt"
  echo "branch:   $(jq -r .branch <<<"$t")   base: $b   HEAD: $(jq -r .head <<<"$facts")"
  echo "owns:     $(jq -r '.owns|join(", ")' <<<"$t")"
  echo "---- commits ahead of base ----"
  git -C "$wt" --no-pager log --oneline "$b..HEAD"
  echo "---- uncommitted ----"
  git -C "$wt" status --short
  echo "---- diff stat ----"
  git -C "$wt" --no-pager diff --stat "$(git -C "$wt" merge-base "$b" HEAD)" HEAD
  echo "---- scope check ----"
  v="$(scope_violations "$id" "$wt" "$base")"
  if [[ -n "$v" ]]; then echo "OUT OF SCOPE:"; sed 's/^/  /' <<<"$v"; else echo "ok: all changes inside owned paths"; fi
  echo "---- last verification ----"
  jq -r --arg h "$(jq -r .head <<<"$facts")" '(.verifications|last) as $v |
    if $v == null then "none (run: verify <worker>)"
    else "\($v.finishedAt) exit=\($v.exitCode) sha=\($v.sha[0:8]) clean=\($v.clean) consistent=\($v.consistent)"
         + (if $v.sha != $h then "  STALE: HEAD moved since" else "" end) + "\n  log: \($v.log)" end' <<<"$t"
  echo
  echo "full diff: git -C '$wt' diff $b...HEAD"
  echo "next:      verify $1  ->  accept $1 [--note ...]  |  reject $1 \"what to fix\""
  sql "UPDATE tasks SET status='reviewing', updated_at=$(q "$(now)") WHERE id=$(q "$id") AND status IN ($ACTIVE_SQL);"
}

cmd_verify() {
  if [[ "${1:-}" == "--lead" ]]; then LEAD="$2"; shift 2; fi
  local fresh=0 ref=""
  while [[ $# -gt 0 ]]; do case "$1" in
    --clean-checkout) fresh=1; shift;;  -*) die "verify: unknown option $1";;  *) ref="$1"; shift;; esac; done
  [[ -n "$ref" ]] || die "usage: verify <worker> [--clean-checkout]"
  LEAD="$(resolve_lead "$LEAD")"; require_lead "run this command"
  local id t tc wt facts head clean log start rc consistent=true run_dir
  id="$(resolve_worker "$ref")"; t="$(task_json "$id")"
  tc="$(state -r '.testCommand // ""')"
  [[ -n "$tc" ]] || die "no test command set; run: config --test-cmd \"...\""
  wt="$(worktree_of "$id")"
  facts="$(wt_facts "$wt" "$(jq -r .base <<<"$t")")"
  jq -e .exists <<<"$facts" >/dev/null || die "worker worktree not found (${wt:-unknown})"
  head="$(jq -r .head <<<"$facts")"
  clean="$(jq -r 'if .modified then "false" else "true" end' <<<"$facts")"
  run_dir="$wt"
  if [[ $fresh -eq 1 ]]; then
    # exact verification: detached checkout of HEAD, nothing uncommitted can leak in (deps must be installed by the test command)
    clean=true; run_dir="$(mktemp -d "${TMPDIR:-/tmp}/xh-verify.XXXXXX")"
    git -C "$wt" worktree add -q --detach "$run_dir" "$head" || die "could not create clean checkout"
  else
    if [[ "$clean" == "false" ]]; then warn "tracked files modified; this run is recorded but cannot back an acceptance"; fi
    if [[ "$(jq '.untracked|length' <<<"$facts")" != "0" ]]; then
      warn "untracked files present (not part of the commit, may hide a missing 'git add'; --clean-checkout rules this out): $(jq -r '.untracked|join(" ")' <<<"$facts")"
    fi
  fi
  mkdir -p "$STATE_ROOT/$LEAD/logs"
  log="$STATE_ROOT/$LEAD/logs/${id:0:8}-${head:0:12}-$(date +%s).log"
  start="$(now)"
  echo "running in $run_dir: $tc"
  rc="$(run_logged "$run_dir" "$log" "$tc")"
  if [[ $fresh -eq 1 ]]; then git -C "$wt" worktree remove --force "$run_dir" >/dev/null 2>&1 || rm -rf "$run_dir"; fi
  if [[ "$(git -C "$wt" rev-parse HEAD)" != "$head" ]]; then consistent=false; fi
  # test runs may create untracked artefacts (__pycache__, coverage); only tracked changes break consistency
  if [[ $fresh -eq 0 && "$clean" == "true" && -n "$(git -C "$wt" status --porcelain --untracked-files=no)" ]]; then consistent=false; fi
  if [[ "$consistent" == "false" ]]; then warn "HEAD or worktree changed during the run; result cannot back an acceptance"; fi
  tail -n 15 "$log" | sed 's/^/  | /'
  local fin; fin="$(now)"
  tx "INSERT INTO verifications(task_id,sha,command,exit_code,clean,consistent,started_at,finished_at,log)
        VALUES ($(q "$id"),$(q "$head"),$(q "$tc"),$(qi "$rc"),$([[ $clean == true ]] && echo 1 || echo 0),
                $([[ $consistent == true ]] && echo 1 || echo 0),$(q "$start"),$(q "$fin"),$(q "$log"));
      UPDATE tasks SET updated_at=$(q "$fin") WHERE id=$(q "$id");"
  if [[ "$rc" == "0" ]]; then echo "PASS at ${head:0:12} (log: $log)"
  else echo "FAIL exit=$rc at ${head:0:12} (log: $log)"; return 1; fi
}

cmd_accept() {
  local ref="" note="" scope_reason=""
  while [[ $# -gt 0 ]]; do case "$1" in
    --lead) LEAD="$2"; shift 2;;  --note) note="$2"; shift 2;;
    --allow-out-of-scope) scope_reason="$2"; shift 2;;
    -*) die "accept: unknown option $1";;  *) ref="$1"; shift;; esac; done
  [[ -n "$ref" ]] || die "usage: accept <worker> [--note text] [--allow-out-of-scope reason]"
  LEAD="$(resolve_lead "$LEAD")"; require_lead "run this command"
  local id t wt base facts head tc problems="" v oos
  id="$(resolve_worker "$ref")"; t="$(task_json "$id")"
  wt="$(worktree_of "$id")"; base="$(jq -r .base <<<"$t")"
  facts="$(wt_facts "$wt" "$base")"
  jq -e .exists <<<"$facts" >/dev/null || die "worker worktree not found (${wt:-unknown})"
  head="$(jq -r .head <<<"$facts")"
  tc="$(state -r '.testCommand // ""')"

  if jq -e .modified <<<"$facts" >/dev/null; then problems+="  - tracked files have uncommitted changes"$'\n'; fi
  if [[ "$(jq -r .ahead <<<"$facts")" == "0" ]]; then problems+="  - branch has no commits ahead of $base"$'\n'; fi
  v="$(jq -c '.verifications | last // empty' <<<"$t")"
  if [[ -z "$v" ]]; then
    problems+="  - never verified (run: verify $ref)"$'\n'
  else
    if [[ "$(jq -r .sha <<<"$v")" != "$head" ]]; then
      problems+="  - last verification is for $(jq -r '.sha[0:8]' <<<"$v") but HEAD is ${head:0:8} (re-run verify)"$'\n'; fi
    if [[ "$(jq -r .exitCode <<<"$v")" != "0" ]]; then
      problems+="  - last verification failed (exit $(jq -r .exitCode <<<"$v"))"$'\n'; fi
    if [[ "$(jq -r '.clean and .consistent' <<<"$v")" != "true" ]]; then
      problems+="  - last verification ran on a dirty or changing worktree"$'\n'; fi
    if [[ "$(jq -r .command <<<"$v")" != "$tc" ]]; then
      problems+="  - verification used a different test command than the current one"$'\n'; fi
  fi
  oos="$(scope_violations "$id" "$wt" "$base")"
  if [[ -n "$oos" && -z "$scope_reason" ]]; then
    problems+="  - changes outside owned paths: $(tr '\n' ' ' <<<"$oos")(override: --allow-out-of-scope \"reason\")"$'\n'
  fi
  if [[ -n "$problems" ]]; then printf 'cannot accept %s:\n%s' "$ref" "$problems" >&2; exit 1; fi

  local ts acc; ts="$(now)"
  acc="$(jq -c --arg sha "$head" --arg note "$note" --arg sr "$scope_reason" --arg oos "$oos" --arg t "$ts" \
    '{sha:$sha, at:$t, note:$note,
      verification:{command:.command, exitCode:.exitCode, finishedAt:.finishedAt, log:.log},
      outOfScope:($oos|split("\n")|map(select(.!=""))),
      outOfScopeReason:(if $sr=="" then null else $sr end)}' <<<"$v")"
  tx "UPDATE tasks SET acceptance=$(q "$acc"), status='accepted', updated_at=$(q "$ts") WHERE id=$(q "$id");
      INSERT INTO reviews(task_id,result,sha,note,at) VALUES ($(q "$id"),'accepted',$(q "$head"),$(qn "$note"),$(q "$ts"));"
  render_charter
  msg "$id" "[LEAD] Accepted at ${head:0:12}. Do not commit further unless asked; any new commit invalidates this acceptance."
  echo "accepted $ref at ${head:0:12}"
}

cmd_reject() {
  if [[ "${1:-}" == "--lead" ]]; then LEAD="$2"; shift 2; fi
  [[ $# -ge 2 ]] || die "usage: reject <worker> \"what to fix\""
  LEAD="$(resolve_lead "$LEAD")"; require_lead "run this command"
  local id head
  id="$(resolve_worker "$1")"
  head="$(wt_facts "$(worktree_of "$id")" "$(task_json "$id" | jq -r .base)" | jq -r '.head // ""')"
  local t; t="$(now)"
  tx "INSERT INTO reviews(task_id,result,sha,note,at) VALUES ($(q "$id"),'changes_requested',$(qn "$head"),$(q "$2"),$(q "$t"));
      INSERT INTO invalidations(task_id,acceptance,reason,at)
        SELECT id, acceptance, 'rejected', $(q "$t") FROM tasks WHERE id=$(q "$id") AND acceptance IS NOT NULL;
      UPDATE tasks SET acceptance=NULL, status='changes_requested', updated_at=$(q "$t") WHERE id=$(q "$id");"
  render_charter
  msg "$id" "[LEAD] Changes requested: $2 -- fix, commit, run the test command, then report READY again."
  echo "changes requested from $1"
}

cmd_cancel() {
  if [[ "${1:-}" == "--lead" ]]; then LEAD="$2"; shift 2; fi
  [[ -n "${1:-}" ]] || die "usage: cancel <worker> [reason]"
  LEAD="$(resolve_lead "$LEAD")"; require_lead "run this command"
  local id; id="$(resolve_worker "$1")"
  "$XIRP" session stop "$id" >/dev/null 2>&1 || warn "could not stop session ${id:0:8} (already stopped?)"
  sql "UPDATE tasks SET status='cancelled', cancel_reason=$(q "${2:-cancelled by lead}"), updated_at=$(q "$(now)") WHERE id=$(q "$id");"
  render_charter
  echo "cancelled $1 (worktree and branch kept; finish --cleanup checks them before deletion)"
}
