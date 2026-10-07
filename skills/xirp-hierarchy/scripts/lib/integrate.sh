# shellcheck shell=bash
# Integration and completion: integrate, deploy-check, finish.

lead_repo() { # explicit-or-empty -> repo path on the integration branch
  local repo="$1"
  [[ -n "$repo" ]] || repo="$(git rev-parse --show-toplevel 2>/dev/null)" || die "run inside the lead checkout or pass --repo"
  echo "$repo"
}

cmd_integrate() {
  local repo="" dry=0 order=""
  while [[ $# -gt 0 ]]; do case "$1" in
    --lead) LEAD="$2"; shift 2;;  --repo) repo="$2"; shift 2;;
    --dry-run) dry=1; shift;;  --order) order="$2"; shift 2;;
    *) die "integrate: unknown option $1";; esac; done
  LEAD="$(resolve_lead "$LEAD")"
  repo="$(lead_repo "$repo")"
  local base cur
  base="$(state -r .baseBranch)"; cur="$(git -C "$repo" branch --show-current)"
  [[ "$cur" == "$base" ]] || die "$repo is on '$cur'; check out the integration branch '$base' first"
  [[ -z "$(git -C "$repo" status --porcelain)" ]] || die "$repo has uncommitted changes"

  local pending
  pending="$(state -r --argjson a "$ACTIVE" '.tasks[] | select(.status as $s | $a | index($s)) | "\(.name) (\(.status))"')"
  if [[ -n "$pending" ]]; then warn "not accepted, will not be integrated:"; sed 's/^/    /' <<<"$pending" >&2; fi

  local ids="" r
  if [[ -n "$order" ]]; then
    for r in $(tr ',' ' ' <<<"$order"); do ids+="$(resolve_worker "$r")"$'\n'; done
  else
    ids="$(state -r '[.tasks[] | select(.status=="accepted")] | sort_by(.createdAt) | .[].id')"
  fi
  if [[ -z "$ids" ]]; then echo "nothing accepted to integrate"; return; fi

  # Pre-flight: every task must still be accepted at the SHA its worktree holds.
  local id t name sha wt head
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    t="$(task_json "$id")"; name="$(jq -r .name <<<"$t")"
    [[ "$(jq -r .status <<<"$t")" == "accepted" ]] || die "'$name' is $(jq -r .status <<<"$t"), not accepted"
    sha="$(jq -r .acceptance.sha <<<"$t")"
    wt="$(worktree_of "$id")"
    if [[ -n "$wt" && -d "$wt" ]]; then
      head="$(git -C "$wt" rev-parse HEAD)"
      [[ "$head" == "$sha" ]] || die "'$name' acceptance is STALE (accepted ${sha:0:8}, branch now ${head:0:8}); verify and accept again"
    fi
  done <<<"$ids"

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    t="$(task_json "$id")"; name="$(jq -r .name <<<"$t")"; sha="$(jq -r .acceptance.sha <<<"$t")"
    if git -C "$repo" merge-base --is-ancestor "$sha" HEAD; then
      echo "already integrated: $name @ ${sha:0:8}"
    elif [[ $dry -eq 1 ]]; then
      echo "would merge: $name @ ${sha:0:8} ($(jq -r .branch <<<"$t"))"; continue
    elif git -C "$repo" merge --no-ff -q -m "Merge hierarchy task '$name' ($(jq -r .branch <<<"$t")@${sha:0:12})" "$sha"; then
      echo "merged: $name @ ${sha:0:8}"
    else
      git -C "$repo" merge --abort >/dev/null 2>&1 || true
      die "merge conflict integrating '$name' (aborted, nothing changed for this task). Have the worker rebase onto $base, then verify + accept again"
    fi
    tasks_update "$LEAD" --arg id "$id" --arg sha "$sha" --arg mc "$(git -C "$repo" rev-parse HEAD)" --arg t "$(now)" \
      '(.tasks[] | select(.id==$id)) |= (.integration={sha:$sha, mergeCommit:$mc, at:$t} | .status="integrated" | .updatedAt=$t)'
  done <<<"$ids"
  if [[ $dry -eq 1 ]]; then return; fi
  integration_test "$repo"
}

integration_test() { # repo — run the test command on the integrated HEAD and record it
  local repo="$1" tc head log rc s
  tc="$(state -r '.testCommand // ""')"
  if [[ -z "$tc" ]]; then warn "no test command; integrated result is untested and deploy-check will fail"; return; fi
  head="$(git -C "$repo" rev-parse HEAD)"
  mkdir -p "$STATE_ROOT/$LEAD/logs"
  log="$STATE_ROOT/$LEAD/logs/integration-${head:0:12}-$(date +%s).log"
  s="$(now)"
  echo "running integration tests in $repo: $tc"
  rc="$(run_logged "$repo" "$log" "$tc")"
  tail -n 15 "$log" | sed 's/^/  | /'
  tasks_update "$LEAD" --arg sha "$head" --arg cmd "$tc" --argjson rc "$rc" --arg s "$s" --arg f "$(now)" --arg log "$log" \
    '.integrationRuns += [{sha:$sha, command:$cmd, exitCode:$rc, startedAt:$s, finishedAt:$f, log:$log}]'
  if [[ "$rc" == "0" ]]; then echo "integration PASS at ${head:0:12}"
  else echo "integration FAIL exit=$rc at ${head:0:12} (log: $log). Do not deploy."; return 1; fi
}

cmd_deploy_check() {
  local repo=""
  while [[ $# -gt 0 ]]; do case "$1" in
    --lead) LEAD="$2"; shift 2;;  --repo) repo="$2"; shift 2;;
    *) die "deploy-check: unknown option $1";; esac; done
  LEAD="$(resolve_lead "$LEAD")"
  repo="$(lead_repo "$repo")"
  local head problems="" open run
  head="$(git -C "$repo" rev-parse HEAD)"
  [[ "$(git -C "$repo" branch --show-current)" == "$(state -r .baseBranch)" ]] || problems+="  - not on the integration branch"$'\n'
  [[ -z "$(git -C "$repo" status --porcelain)" ]] || problems+="  - uncommitted changes in $repo"$'\n'
  open="$(state -r '.tasks[] | select(.status!="integrated" and .status!="cancelled") | "\(.name) (\(.status))"')"
  if [[ -n "$open" ]]; then problems+="  - tasks not integrated: $(tr '\n' ' ' <<<"$open")"$'\n'; fi
  run="$(state -c --arg h "$head" '[.integrationRuns[] | select(.sha==$h)] | last // empty')"
  if [[ -z "$run" ]]; then problems+="  - no integration test run at HEAD ${head:0:12} (run: integrate)"$'\n'
  elif [[ "$(jq -r .exitCode <<<"$run")" != "0" ]]; then problems+="  - integration tests failed at HEAD ${head:0:12}"$'\n'
  elif [[ "$(jq -r .command <<<"$run")" != "$(state -r '.testCommand')" ]]; then problems+="  - test command changed since the last run"$'\n'; fi
  if [[ -n "$problems" ]]; then printf 'NOT READY TO DEPLOY:\n%s' "$problems"; return 1; fi
  echo "READY TO DEPLOY: ${head:0:12} — all tasks integrated, tests passed ($(jq -r .finishedAt <<<"$run"))"
  echo "follow the charter's Deployment section; ask the user first unless it says Pre-authorised: yes"
}

cmd_finish() {
  local cleanup=0 delbranch=0 force=0
  while [[ $# -gt 0 ]]; do case "$1" in
    --lead) LEAD="$2"; shift 2;;  --cleanup) cleanup=1; shift;;
    --delete-branches) delbranch=1; shift;;  --force) force=1; shift;;
    *) die "finish: unknown option $1";; esac; done
  LEAD="$(resolve_lead "$LEAD")"

  # Inspect every task. Hard blocks (dirty) are never deleted; soft blocks need --force.
  local id t name st wt facts hard="" soft="" deletable=""
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    t="$(task_json "$id")"; name="$(jq -r .name <<<"$t")"; st="$(jq -r .status <<<"$t")"
    wt="$(worktree_of "$id")"
    facts="$(wt_facts "$wt" "$(jq -r .base <<<"$t")" 2>/dev/null || echo '{"exists":false}')"
    if [[ "$st" != "integrated" && "$st" != "cancelled" ]]; then soft+="  - '$name' is $st, not integrated"$'\n'; fi
    if jq -e .exists <<<"$facts" >/dev/null; then
      if jq -e .dirty <<<"$facts" >/dev/null; then
        hard+="  - '$name' has uncommitted changes in $wt (will not be deleted)"$'\n'; continue
      fi
      if ! jq -e '.merged or .ahead==0' <<<"$facts" >/dev/null; then
        soft+="  - '$name' has $(jq -r .ahead <<<"$facts") commit(s) not in the base branch"$'\n'
      fi
    fi
    deletable+="$id"$'\n'
  done < <(state -r '.tasks[].id')

  if [[ -n "$hard" ]]; then printf 'blocked (never auto-deleted):\n%s' "$hard"; fi
  if [[ -n "$soft" ]]; then printf 'unfinished work:\n%s' "$soft"; fi
  if [[ -n "$soft" && $force -eq 0 ]]; then
    die "refusing to finish with unintegrated work; integrate it, cancel it deliberately, or pass --force"
  fi

  tasks_update "$LEAD" --arg t "$(now)" '.status="done" | .finishedAt=$t'
  echo "hierarchy $LEAD marked done (state kept at $STATE_ROOT/$LEAD)"
  if [[ $cleanup -eq 0 ]]; then return; fi

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    t="$(task_json "$id")"
    facts="$(wt_facts "$(worktree_of "$id")" "$(jq -r .base <<<"$t")" 2>/dev/null || echo '{"exists":false}')"
    local args=(session delete "$id" --yes --delete-worktree)
    # never delete a branch carrying commits that are not in the base branch
    if [[ $delbranch -eq 1 ]] && jq -e '(.exists|not) or .merged or .ahead==0' <<<"$facts" >/dev/null; then
      args+=(--delete-branch)
    fi
    "$XIRP" session stop "$id" >/dev/null 2>&1 || true
    if "$XIRP" "${args[@]}" >/dev/null 2>&1; then echo "deleted session ${id:0:8} ($(jq -r .name <<<"$t"))"
    else warn "could not delete session ${id:0:8}"; fi
  done <<<"$deletable"
}
