# shellcheck shell=bash
# Review gate: review, verify, accept, reject, cancel.
# Acceptance is bound to a commit SHA; any new commit invalidates it.

cmd_review() {
  if [[ "${1:-}" == "--lead" ]]; then LEAD="$2"; shift 2; fi
  [[ -n "${1:-}" ]] || die "usage: review <worker>"
  LEAD="$(resolve_lead "$LEAD")"
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
  tasks_update "$LEAD" --arg id "$id" --arg t "$(now)" --argjson a "$ACTIVE" \
    '(.tasks[] | select(.id==$id and (.status as $s | $a | index($s)))) |= (.status="reviewing" | .updatedAt=$t)'
}

cmd_verify() {
  if [[ "${1:-}" == "--lead" ]]; then LEAD="$2"; shift 2; fi
  [[ -n "${1:-}" ]] || die "usage: verify <worker>"
  LEAD="$(resolve_lead "$LEAD")"
  local id t tc wt facts head clean log start rc consistent=true
  id="$(resolve_worker "$1")"; t="$(task_json "$id")"
  tc="$(state -r '.testCommand // ""')"
  [[ -n "$tc" ]] || die "no test command set; run: config --test-cmd \"...\""
  wt="$(worktree_of "$id")"
  facts="$(wt_facts "$wt" "$(jq -r .base <<<"$t")")"
  jq -e .exists <<<"$facts" >/dev/null || die "worker worktree not found (${wt:-unknown})"
  head="$(jq -r .head <<<"$facts")"
  clean="$(jq -r 'if .dirty then "false" else "true" end' <<<"$facts")"
  if [[ "$clean" == "false" ]]; then warn "worktree has uncommitted changes; this run is recorded but cannot back an acceptance"; fi
  mkdir -p "$STATE_ROOT/$LEAD/logs"
  log="$STATE_ROOT/$LEAD/logs/${id:0:8}-${head:0:12}-$(date +%s).log"
  start="$(now)"
  echo "running in $wt: $tc"
  rc="$(run_logged "$wt" "$log" "$tc")"
  if [[ "$(git -C "$wt" rev-parse HEAD)" != "$head" ]]; then consistent=false; fi
  if [[ "$clean" == "true" && -n "$(git -C "$wt" status --porcelain)" ]]; then consistent=false; fi
  if [[ "$consistent" == "false" ]]; then warn "HEAD or worktree changed during the run; result cannot back an acceptance"; fi
  tail -n 15 "$log" | sed 's/^/  | /'
  tasks_update "$LEAD" --arg id "$id" --arg sha "$head" --arg cmd "$tc" --argjson rc "$rc" \
    --argjson clean "$clean" --argjson cons "$consistent" --arg s "$start" --arg f "$(now)" --arg log "$log" \
    '(.tasks[] | select(.id==$id)) |= (.verifications += [{sha:$sha, command:$cmd, exitCode:$rc, clean:$clean,
       consistent:$cons, startedAt:$s, finishedAt:$f, log:$log}] | .updatedAt=$f)'
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
  LEAD="$(resolve_lead "$LEAD")"
  local id t wt base facts head tc problems="" v oos
  id="$(resolve_worker "$ref")"; t="$(task_json "$id")"
  wt="$(worktree_of "$id")"; base="$(jq -r .base <<<"$t")"
  facts="$(wt_facts "$wt" "$base")"
  jq -e .exists <<<"$facts" >/dev/null || die "worker worktree not found (${wt:-unknown})"
  head="$(jq -r .head <<<"$facts")"
  tc="$(state -r '.testCommand // ""')"

  if jq -e .dirty <<<"$facts" >/dev/null; then problems+="  - worktree has uncommitted changes"$'\n'; fi
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

  tasks_update "$LEAD" --arg id "$id" --arg sha "$head" --arg note "$note" --arg sr "$scope_reason" \
    --arg oos "$oos" --arg t "$(now)" \
    '(.tasks[] | select(.id==$id)) |= (
       (.verifications|last) as $v
       | .acceptance = {sha:$sha, at:$t, note:$note,
                        verification:{command:$v.command, exitCode:$v.exitCode, finishedAt:$v.finishedAt, log:$v.log},
                        outOfScope:($oos|split("\n")|map(select(.!=""))),
                        outOfScopeReason:(if $sr=="" then null else $sr end)}
       | .reviews += [{result:"accepted", sha:$sha, note:$note, at:$t}]
       | .status="accepted" | .updatedAt=$t)'
  msg "$id" "[LEAD] Accepted at ${head:0:12}. Do not commit further unless asked; any new commit invalidates this acceptance."
  echo "accepted $ref at ${head:0:12}"
}

cmd_reject() {
  if [[ "${1:-}" == "--lead" ]]; then LEAD="$2"; shift 2; fi
  [[ $# -ge 2 ]] || die "usage: reject <worker> \"what to fix\""
  LEAD="$(resolve_lead "$LEAD")"
  local id head
  id="$(resolve_worker "$1")"
  head="$(wt_facts "$(worktree_of "$id")" "$(task_json "$id" | jq -r .base)" | jq -r '.head // ""')"
  tasks_update "$LEAD" --arg id "$id" --arg sha "$head" --arg note "$2" --arg t "$(now)" \
    '(.tasks[] | select(.id==$id)) |= (
       .reviews += [{result:"changes_requested", sha:$sha, note:$note, at:$t}]
       | (if .acceptance != null then .invalidated += [.acceptance + {invalidatedAt:$t, reason:"rejected"}] else . end)
       | .acceptance=null | .status="changes_requested" | .updatedAt=$t)'
  msg "$id" "[LEAD] Changes requested: $2 -- fix, commit, run the test command, then report READY again."
  echo "changes requested from $1"
}

cmd_cancel() {
  if [[ "${1:-}" == "--lead" ]]; then LEAD="$2"; shift 2; fi
  [[ -n "${1:-}" ]] || die "usage: cancel <worker> [reason]"
  LEAD="$(resolve_lead "$LEAD")"
  local id; id="$(resolve_worker "$1")"
  "$XIRP" session stop "$id" >/dev/null 2>&1 || warn "could not stop session ${id:0:8} (already stopped?)"
  tasks_update "$LEAD" --arg id "$id" --arg r "${2:-cancelled by lead}" --arg t "$(now)" \
    '(.tasks[] | select(.id==$id)) |= (.status="cancelled" | .cancelReason=$r | .updatedAt=$t)'
  echo "cancelled $1 (worktree and branch kept; finish --cleanup checks them before deletion)"
}
