# shellcheck shell=bash
# Lead commands: init, config, spawn, status, tell, broadcast, inbox, charter.

cmd_init() {
  local lead="${CHIRP_SESSION_ID:-}" base="" project="" tc="" maxw=3 maxm=120 maxc=10 force=0
  while [[ $# -gt 0 ]]; do case "$1" in
    --lead) lead="$2"; shift 2;;  --base-branch) base="$2"; shift 2;;
    --project) project="$2"; shift 2;;  --test-cmd) tc="$2"; shift 2;;
    --max-workers) maxw="$2"; shift 2;;  --max-minutes) maxm="$2"; shift 2;;
    --max-cost) maxc="$2"; shift 2;;  --force) force=1; shift;;
    *) die "init: unknown option $1";; esac; done
  [[ -n "$lead" ]] || die "init must run inside the lead session (or pass --lead <id>)"
  local dir="$STATE_ROOT/$lead"
  if [[ -f "$dir/tasks.json" && $force -eq 0 ]]; then
    echo "already initialised: $dir (use --force to overwrite)"; return
  fi
  mkdir -p "$dir/logs"
  [[ -n "$project" ]] || project="${CHIRP_PROJECT_ID:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  if [[ -z "$base" ]]; then
    base="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
    [[ -n "$base" ]] || base="$(git branch --show-current 2>/dev/null || true)"
    [[ -n "$base" ]] || base=main
  fi
  render_template "$SKILL_DIR/assets/charter-template.md" \
    "LEAD_ID=$lead" "PROJECT=$project" "BASE_BRANCH=$base" "CREATED_AT=$(now)" \
    "TEST_CMD=${tc:-<not set: hierarchy.sh config --test-cmd \"...\">}" \
    "MAX_WORKERS=$maxw" "MAX_MINUTES=$maxm" "MAX_COST=$maxc" >"$dir/charter.md"
  local tmp; tmp="$(mktemp "$dir/tasks.json.tmp.XXXXXX")"
  jq -n --arg lead "$lead" --arg base "$base" --arg project "$project" --arg tc "$tc" \
        --argjson mw "$maxw" --argjson mm "$maxm" --argjson mc "$maxc" --arg t "$(now)" \
    '{version:2, lead:$lead, baseBranch:$base, project:$project,
      testCommand:(if $tc=="" then null else $tc end),
      limits:{maxWorkers:$mw, maxMinutes:$mm, maxCostUsd:$mc},
      status:"active", createdAt:$t, tasks:[], integrationRuns:[]}' >"$tmp"
  mv "$tmp" "$dir/tasks.json"
  local cur; cur="$(session_json "$lead" 2>/dev/null | jq -r '.name // ""' || true)"
  if [[ -n "$cur" && "$cur" != LEAD:* ]]; then
    "$XIRP" session update "$lead" --name "LEAD: $cur" >/dev/null 2>&1 || true
  fi
  echo "lead:    $lead"
  echo "charter: $dir/charter.md"
  echo "limits:  $maxw workers, ${maxm} min/worker, \$${maxc}/worker"
  if [[ -z "$tc" ]]; then echo "next:    set the test command: hierarchy.sh config --test-cmd \"...\""; fi
  echo "next:    fill the charter, then spawn workers with explicit --owns"
}

cmd_config() {
  local tc="" maxw="" maxm="" maxc="" f='.'
  while [[ $# -gt 0 ]]; do case "$1" in
    --lead) LEAD="$2"; shift 2;;  --test-cmd) tc="$2"; shift 2;;
    --max-workers) maxw="$2"; shift 2;;  --max-minutes) maxm="$2"; shift 2;;
    --max-cost) maxc="$2"; shift 2;;
    *) die "config: unknown option $1";; esac; done
  LEAD="$(resolve_lead "$LEAD")"
  if [[ -n "$tc"   ]]; then f="$f | .testCommand=\$tc"; fi
  if [[ -n "$maxw" ]]; then f="$f | .limits.maxWorkers=(\$mw|tonumber)"; fi
  if [[ -n "$maxm" ]]; then f="$f | .limits.maxMinutes=(\$mm|tonumber)"; fi
  if [[ -n "$maxc" ]]; then f="$f | .limits.maxCostUsd=(\$mc|tonumber)"; fi
  if [[ "$f" != "." ]]; then
    tasks_update "$LEAD" --arg tc "$tc" --arg mw "${maxw:-0}" --arg mm "${maxm:-0}" --arg mc "${maxc:-0}" "$f"
  fi
  state '{lead, baseBranch, testCommand, limits, status}'
}

cmd_spawn() {
  local name="" branch="" goal="" after="" base="" force=0 owns_raw="" extra=()
  while [[ $# -gt 0 ]]; do case "$1" in
    --lead) LEAD="$2"; shift 2;;  --name) name="$2"; shift 2;;
    --branch) branch="$2"; shift 2;;  --goal) goal="$2"; shift 2;;
    --after) after="$2"; shift 2;;  --base-branch) base="$2"; shift 2;;
    --owns) owns_raw="${owns_raw:+$owns_raw,}$2"; shift 2;;
    --force) force=1; shift;;  --foreground|--auto-mode|--no-terminal) extra+=("$1"); shift;;
    --harness|--model|--profile|--project) extra+=("$1" "$2"); shift 2;;
    *) die "spawn: unknown option $1";; esac; done
  LEAD="$(resolve_lead "$LEAD")"
  [[ -n "$name" ]] || die "spawn: --name required"
  [[ -n "$goal" ]] || die "spawn: --goal required"
  [[ -n "$owns_raw" ]] || die "spawn: --owns <paths> required (comma-separated files/dirs this worker may change)"
  local dir="$STATE_ROOT/$LEAD"
  [[ -n "$base" ]] || base="$(state -r '.baseBranch')"
  if [[ -z "$branch" ]]; then
    branch="hier/$(printf '%s' "$name" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | cut -c1-40)"
  fi
  if [[ -z "$(state -r '.testCommand // ""')" ]]; then
    warn "no test command set; workers cannot be verified/accepted until: config --test-cmd \"...\""
  fi

  local owns_json p
  owns_json="$(printf '%s\n' "$owns_raw" | tr ',' '\n' | sed 's/^ *//; s/ *$//; /^$/d' \
               | while IFS= read -r p; do norm_path "$p"; done | jq -R . | jq -sc 'unique')"
  [[ "$(jq length <<<"$owns_json")" -gt 0 ]] || die "spawn: --owns parsed to no paths"

  local after_id=""
  if [[ -n "$after" ]]; then
    after_id="$(state -r --arg r "$after" '.tasks[] | select(.name==$r or .branch==$r or (.id|startswith($r))) | .id' | head -n1)"
    [[ -n "$after_id" ]] || after_id="$after"
  fi

  # bounded coordination: worker slots
  local active maxw
  active="$(state --argjson a "$ACTIVE" '[.tasks[] | select(.status as $s | $a | index($s))] | length')"
  maxw="$(state '.limits.maxWorkers')"
  if [[ $active -ge $maxw && $force -eq 0 ]]; then
    die "worker limit reached ($active active / max $maxw). Accept, cancel or integrate a worker, raise config --max-workers, or pass --force"
  fi

  # explicit file ownership: no overlap with other owning tasks except the one we run --after
  local conflicts="" oid oname opath
  while IFS=$'\t' read -r oid oname opath; do
    [[ -n "$oid" ]] || continue
    if [[ "$oid" == "$after_id" ]]; then continue; fi
    while IFS= read -r p; do
      if path_under "$p" "$opath" || path_under "$opath" "$p"; then
        conflicts="${conflicts}  '$p' overlaps '$opath' owned by '$oname' (${oid:0:8})"$'\n'
      fi
    done < <(jq -r '.[]' <<<"$owns_json")
  done < <(state -r --argjson o "$OWNING" \
             '.tasks[] | select(.status as $s | $o | index($s)) | .id as $i | .name as $n | .owns[] | [$i,$n,.] | @tsv')
  if [[ -n "$conflicts" ]]; then
    printf 'error: file ownership overlap:\n%s' "$conflicts" >&2
    die "narrow --owns, or sequence this task with --after <that worker>"
  fi

  local brief
  brief="$(render_template "$SKILL_DIR/assets/worker-brief.md" \
    "LEAD_ID=$LEAD" "TASK_NAME=$name" "CHARTER_PATH=$dir/charter.md" "SKILL_DIR=$SKILL_DIR" \
    "OWNS=$(jq -r 'join(", ")' <<<"$owns_json")" "BRANCH=$branch" "BASE_BRANCH=$base" \
    "TEST_CMD=$(state -r '.testCommand // "(ask the lead)"')" \
    "MAX_MINUTES=$(state -r '.limits.maxMinutes')" "MAX_COST=$(state -r '.limits.maxCostUsd')" \
    "GOAL=$goal")"

  local args=(session new --goal "$brief" --name "W: $name" --new-branch "$branch" --base-branch "$base"
              --parent "$LEAD" --tag "role:worker" --tag "lead:$LEAD" --json)
  if [[ -n "$after_id" ]]; then args+=(--depends-on "$after_id"); fi
  args+=(${extra[@]+"${extra[@]}"})

  local out id wt
  out="$("$XIRP" "${args[@]}")"
  id="$(jq -r '.id // .session.id // empty' <<<"$out" 2>/dev/null || true)"
  if [[ -z "$id" ]]; then
    echo "$out" >&2
    die "could not read new session id from xirp output; a session may exist untracked — check 'xirp session list'"
  fi
  wt="$(session_json "$id" 2>/dev/null | jq -r '.worktreePath // empty' || true)"

  local task
  task="$(jq -nc --arg id "$id" --arg name "$name" --arg branch "$branch" --arg base "$base" \
       --argjson owns "$owns_json" --arg goal "$goal" --arg after "$after_id" --arg wt "$wt" --arg t "$(now)" \
       '{id:$id, name:$name, branch:$branch, base:$base, owns:$owns, goal:$goal,
         after:(if $after=="" then null else $after end),
         worktreePath:(if $wt=="" then null else $wt end),
         status:"spawned", createdAt:$t, updatedAt:$t,
         reports:[], verifications:[], reviews:[], acceptance:null, invalidated:[], integration:null}')"
  [[ -n "$task" ]] || die "internal: failed to build task record for session $id"
  tasks_update "$LEAD" --argjson task "$task" '.tasks += [$task]'
  state -e --arg id "$id" 'any(.tasks[]; .id==$id)' >/dev/null \
    || die "session $id was created but is NOT tracked in tasks.json"

  echo "spawned worker: $name"
  echo "  session: $id"
  echo "  branch:  $branch (from $base)"
  echo "  owns:    $(jq -r 'join(", ")' <<<"$owns_json")"
  if [[ -n "$after" ]]; then echo "  queued after: $after"; fi
  echo "add this task to the charter's task table: $dir/charter.md"
}

enriched_tasks() { # -> JSON array of tasks with live session + git facts and flags
  local limits id t sj wt facts
  limits="$(state -c '.limits')"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    t="$(task_json "$id")"
    sj="$(session_json "$id" 2>/dev/null || echo '{}')"
    wt="$(jq -r '.worktreePath // empty' <<<"$sj")"
    [[ -n "$wt" ]] || wt="$(jq -r '.worktreePath // empty' <<<"$t")"
    facts="$(wt_facts "$wt" "$(jq -r .base <<<"$t")" 2>/dev/null || echo '{"exists":false}')"
    jq -c --argjson s "$sj" --argjson f "$facts" --argjson L "$limits" --argjson A "$ACTIVE" --arg wt "$wt" '
      . as $t
      | ((now - (.createdAt|fromdateiso8601)) / 60 | floor) as $mins
      | ($s.totalCostUsd // 0) as $cost
      | (.verifications | last) as $v
      | . + {sessionStatus: ($s.status // "unknown"), worktreePath: $wt, git: $f, minutes: $mins, costUsd: $cost,
             flags: [
               (if .acceptance != null and $f.exists and $f.head != .acceptance.sha then "STALE_ACCEPTANCE" else empty end),
               (if $f.exists and $f.dirty then "DIRTY" else empty end),
               (if .status=="ready" and $f.exists and ($v == null or $v.sha != $f.head) then "UNVERIFIED" else empty end),
               (if ($A|index($t.status)) and $mins > $L.maxMinutes then "OVER_TIME" else empty end),
               (if $cost > $L.maxCostUsd then "OVER_COST" else empty end)
             ]}' <<<"$t"
  done < <(state -r '.tasks[].id') | jq -s .
}

cmd_status() {
  local json=0
  while [[ $# -gt 0 ]]; do case "$1" in
    --lead) LEAD="$2"; shift 2;;  --json) json=1; shift;;
    *) die "status: unknown option $1";; esac; done
  LEAD="$(resolve_lead "$LEAD")"
  local data; data="$(enriched_tasks)"
  if [[ $json -eq 1 ]]; then echo "$data"; return; fi
  echo "lead: $LEAD   hierarchy: $(state -r .status)   limits: $(state -c .limits)"
  echo "charter: $STATE_ROOT/$LEAD/charter.md"
  jq -r '
    (["ID","NAME","TASK","SESSION","HEAD","MIN","COST","OWNS","FLAGS"] | @tsv),
    (.[] | [ .id[0:8], .name[0:28], .status, .sessionStatus,
             (if .git.exists then .git.head[0:8] else "-" end),
             (.minutes|tostring), ("$" + ((.costUsd*100|round)/100|tostring)),
             (.owns|join(",")|.[0:30]), (if (.flags|length)>0 then (.flags|join(",")) else "-" end)] | @tsv)' \
    <<<"$data" | column -t -s $'\t'
  if [[ "$(jq '[.[] | select(.flags|length>0)] | length' <<<"$data")" != "0" ]]; then
    echo
    echo "STALE_ACCEPTANCE → verify + accept again | UNVERIFIED → verify | OVER_TIME/OVER_COST → tell or cancel"
  fi
}

cmd_tell() {
  if [[ "${1:-}" == "--lead" ]]; then LEAD="$2"; shift 2; fi
  [[ $# -ge 2 ]] || die "usage: tell <worker> \"message\""
  LEAD="$(resolve_lead "$LEAD")"
  local id; id="$(resolve_worker "$1")"
  "$XIRP" session message "$id" "[LEAD] $2" --from "$LEAD"
  echo "sent to $1 (${id:0:8})"
}

cmd_broadcast() {
  if [[ "${1:-}" == "--lead" ]]; then LEAD="$2"; shift 2; fi
  [[ -n "${1:-}" ]] || die "usage: broadcast \"message\""
  LEAD="$(resolve_lead "$LEAD")"
  local id st
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    st="$(session_json "$id" 2>/dev/null | jq -r '.status' || echo unknown)"
    case "$st" in
      running|idle|waiting) "$XIRP" session message "$id" "[LEAD] $1" --from "$LEAD" && echo "sent to ${id:0:8}";;
      *) echo "skipped ${id:0:8} ($st)";;
    esac
  done < <(state -r --argjson a "$ACTIVE" '.tasks[] | select(.status as $s | $a | index($s)) | .id')
}

cmd_inbox() {
  local all=0
  while [[ $# -gt 0 ]]; do case "$1" in
    --lead) LEAD="$2"; shift 2;;  --all) all=1; shift;;
    *) die "inbox: unknown option $1";; esac; done
  LEAD="$(resolve_lead "$LEAD")"
  state -r --argjson all "$all" '
    [.tasks[] | .name as $n | .reports[] | . + {name:$n}] | sort_by(.at)
    | (if $all==1 then . else .[-20:] end) | .[]
    | "\(.at)  [\(.kind)] \(.name) @\((.sha // "")[0:8]): \(.text)"'
}

cmd_charter() {
  if [[ "${1:-}" == "--lead" ]]; then LEAD="$2"; fi
  LEAD="$(resolve_lead "$LEAD")"
  echo "$STATE_ROOT/$LEAD/charter.md"
}
