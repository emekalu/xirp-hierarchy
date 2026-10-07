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
  if [[ -f "$dir/state.db" && $force -eq 0 ]]; then
    echo "already initialised: $dir (use --force to overwrite)"; return
  fi
  [[ "$maxw" =~ ^[0-9]+$ && "$maxm" =~ ^[0-9]+$ ]] || die "init: --max-workers/--max-minutes must be integers"
  qf "$maxc" >/dev/null
  mkdir -p "$dir/logs"
  rm -f "$dir/state.db" "$dir/state.db-wal" "$dir/state.db-shm"
  [[ -n "$project" ]] || project="${CHIRP_PROJECT_ID:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  if [[ -z "$base" ]]; then
    base="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
    [[ -n "$base" ]] || base="$(git branch --show-current 2>/dev/null || true)"
    [[ -n "$base" ]] || base=main
  fi
  render_template "$SKILL_DIR/assets/charter-template.md" \
    "LEAD_ID=$lead" "PROJECT=$project" "BASE_BRANCH=$base" "CREATED_AT=$(now)" \
    "MAX_WORKERS=$maxw" "MAX_MINUTES=$maxm" "MAX_COST=$maxc" >"$dir/charter.md"
  local db="$dir/state.db"
  sqlite3 "$db" 'PRAGMA journal_mode=WAL;' >/dev/null
  sql_on "$db" "BEGIN; $SCHEMA_SQL
    INSERT INTO hierarchy(id,lead,base_branch,project,test_command,max_workers,max_minutes,max_cost,created_at)
    VALUES (1,$(q "$lead"),$(q "$base"),$(q "$project"),$(qn "$tc"),$maxw,$maxm,$maxc,$(q "$(now)")); COMMIT;"
  sql_on "$db" "$FTS_SQL" 2>/dev/null || warn "SQLite lacks FTS5; ctx search falls back to substring matching"
  LEAD="$lead"; render_charter
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
  local tc="" maxw="" maxm="" maxc="" set=""
  while [[ $# -gt 0 ]]; do case "$1" in
    --lead) LEAD="$2"; shift 2;;  --test-cmd) tc="$2"; shift 2;;
    --max-workers) maxw="$2"; shift 2;;  --max-minutes) maxm="$2"; shift 2;;
    --max-cost) maxc="$2"; shift 2;;
    *) die "config: unknown option $1";; esac; done
  LEAD="$(resolve_lead "$LEAD")"
  if [[ -n "$tc"   ]]; then set="$set, test_command=$(q "$tc")"; fi
  if [[ -n "$maxw" ]]; then set="$set, max_workers=$(qi "$maxw")"; fi
  if [[ -n "$maxm" ]]; then set="$set, max_minutes=$(qi "$maxm")"; fi
  if [[ -n "$maxc" ]]; then set="$set, max_cost=$(qf "$maxc")"; fi
  if [[ -n "$set" ]]; then
    require_lead "change configuration"
    sql "UPDATE hierarchy SET ${set#, } WHERE id=1;"
    render_charter
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
  require_lead "spawn workers"
  if state -e --arg n "$name" 'any(.tasks[]; .name==$n)' >/dev/null; then die "spawn: a worker named '$name' already exists"; fi
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
  # workers belong to the hierarchy's project, not whatever the caller's CWD resolves to
  case " ${extra[*]+"${extra[*]}"} " in *" --project "*) ;; *) args+=(--project "$(state -r .project)");; esac
  args+=(${extra[@]+"${extra[@]}"})

  local out id wt
  out="$("$XIRP" "${args[@]}")"
  id="$(jq -r '.id // .session.id // empty' <<<"$out" 2>/dev/null || true)"
  if [[ -z "$id" ]]; then
    echo "$out" >&2
    die "could not read new session id from xirp output; a session may exist untracked — check 'xirp session list'"
  fi
  wt="$(session_json "$id" 2>/dev/null | jq -r '.worktreePath // empty' || true)"

  local t; t="$(now)"
  sql "INSERT INTO tasks(id,name,branch,base,owns,goal,after_id,worktree_path,status,created_at,updated_at)
       VALUES ($(q "$id"),$(q "$name"),$(q "$branch"),$(q "$base"),$(q "$owns_json"),$(q "$goal"),
               $(qn "$after_id"),$(qn "$wt"),'spawned',$(q "$t"),$(q "$t"));" \
    || die "session $id was created but is NOT tracked; stop it with: xirp session stop $id"
  render_charter

  echo "spawned worker: $name"
  echo "  session: $id"
  echo "  branch:  $branch (from $base)"
  echo "  owns:    $(jq -r 'join(", ")' <<<"$owns_json")"
  if [[ -n "$after" ]]; then echo "  queued after: $after"; fi
  echo "  charter: $dir/charter.md (task table regenerated)"
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
               (if $f.exists and $f.modified then "DIRTY" else empty end),
               (if .status=="ready" and $f.exists and ($v == null or $v.sha != $f.head) then "UNVERIFIED" else empty end),
               (if ($A|index($t.status)) and $mins > $L.maxMinutes then "OVER_TIME" else empty end),
               (if $cost > $L.maxCostUsd then "OVER_COST" else empty end),
               # agent never produced a token: usually an interactive prompt (MCP/trust dialog) in the worker terminal
               (if ($A|index($t.status)) and $mins >= 3 and ($s.status // "") == "running"
                   and (($s.inputTokens // 0) + ($s.outputTokens // 0)) == 0 then "STALLED" else empty end),
               (if $s.waitingReason then "WAITING:" + ($s.waitingReason|tostring) else empty end)
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

lead_text() { # fyi text
  if [[ "$1" -eq 1 ]]; then printf '[LEAD FYI] %s%s' "$2" "$FYI_SUFFIX"; else printf '[LEAD] %s%s' "$2" "$ASK_SUFFIX"; fi
}

cmd_tell() {
  local fyi=0 args=()
  while [[ $# -gt 0 ]]; do case "$1" in
    --lead) LEAD="$2"; shift 2;;  --fyi) fyi=1; shift;;  *) args+=("$1"); shift;; esac; done
  [[ ${#args[@]} -eq 2 ]] || die "usage: tell <worker> \"message\" [--fyi]"
  set -- "${args[@]}"
  LEAD="$(resolve_lead "$LEAD")"; require_lead "run this command"
  local id; id="$(resolve_worker "$1")"
  "$XIRP" session message "$id" "$(lead_text $fyi "$2")" --from "$LEAD"
  echo "sent to $1 (${id:0:8})"
}

cmd_broadcast() {
  local fyi=0 args=()
  while [[ $# -gt 0 ]]; do case "$1" in
    --lead) LEAD="$2"; shift 2;;  --fyi) fyi=1; shift;;  *) args+=("$1"); shift;; esac; done
  [[ ${#args[@]} -eq 1 ]] || die "usage: broadcast \"message\" [--fyi]"
  set -- "${args[@]}"
  LEAD="$(resolve_lead "$LEAD")"; require_lead "run this command"
  local id st text; text="$(lead_text $fyi "$1")"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    st="$(session_json "$id" 2>/dev/null | jq -r '.status' || echo unknown)"
    case "$st" in
      running|idle|waiting) "$XIRP" session message "$id" "$text" --from "$LEAD" && echo "sent to ${id:0:8}";;
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

cmd_dump() {
  if [[ "${1:-}" == "--lead" ]]; then LEAD="$2"; fi
  LEAD="$(resolve_lead "$LEAD")"
  state .
}
