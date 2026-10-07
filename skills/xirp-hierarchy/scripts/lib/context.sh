# shellcheck shell=bash
# Shared context pool (lead-curated) and charter generation.
#
# Lead entries are approved immediately (superseding any approved entry with the same key).
# Worker entries are 'proposed' and invisible to search/charter until the lead approves.

CTX_KINDS="decision interface gotcha finding note"

render_charter() { # regenerate GENERATED blocks in charter.md from state.db
  local charter="$STATE_ROOT/$LEAD/charter.md"
  [[ -f "$charter" ]] || return 0
  local tasks ctx tmp tc lim
  tc="$(state -r '"  ```bash\n  " + (.testCommand // "# not set: hierarchy.sh config --test-cmd \"...\"") + "\n  ```"')"
  lim="$(state -r '"- Max concurrent workers: \(.limits.maxWorkers)\n- Per worker: \(.limits.maxMinutes) minutes, $\(.limits.maxCostUsd) (flagged in `status` as OVER_TIME / OVER_COST)"')"
  tasks="$(state -r '
    if (.tasks|length)==0 then "_No workers yet._" else
    "| # | Worker | Branch | Owns | After | Status | Accepted |",
    "|---|--------|--------|------|-------|--------|----------|",
    (.tasks as $all | .tasks | to_entries[] | .value as $t |
      "| \(.key+1) | \($t.name) | `\($t.branch)` | \($t.owns|map("`"+.+"`")|join(", ")) | " +
      "\(if $t.after then ([$all[]|select(.id==$t.after)|.name] | first // $t.after[0:8]) else "" end) | " +
      "\($t.status) | \(if $t.acceptance then $t.acceptance.sha[0:8] else "" end) |")
    end')"
  ctx="$(sql "SELECT json_group_array(json_object('id',id,'kind',kind,'key',key,'body',body,'task',task_id,'sha',sha,'at',updated_at))
              FROM (SELECT * FROM context WHERE status='approved' ORDER BY kind, key);" | jq -r '
    if length==0 then "_No approved entries yet._" else
    group_by(.kind)[] |
      "### \(.[0].kind | ascii_upcase[0:1] + .[1:])s", "",
      (.[] | "- **\(.key)** (#\(.id)\(if .sha then ", @" + .sha[0:8] else "" end)): \(.body | gsub("\n"; "\n  "))"),
      ""
    end')"
  tmp="$(mktemp "$charter.tmp.XXXXXX")"
  TASKS_BLOCK="$tasks" CTX_BLOCK="$ctx" TC_BLOCK="$tc" LIM_BLOCK="$lim" perl -0pe '
    s/(<!-- BEGIN GENERATED: testcmd -->\n).*?(<!-- END GENERATED: testcmd -->)/$1$ENV{TC_BLOCK}\n$2/s;
    s/(<!-- BEGIN GENERATED: limits -->\n).*?(<!-- END GENERATED: limits -->)/$1$ENV{LIM_BLOCK}\n$2/s;
    s/(<!-- BEGIN GENERATED: tasks[^\n]*-->\n).*?(<!-- END GENERATED: tasks -->)/$1$ENV{TASKS_BLOCK}\n$2/s;
    s/(<!-- BEGIN GENERATED: context[^\n]*-->\n).*?(<!-- END GENERATED: context -->)/$1$ENV{CTX_BLOCK}\n$2/s;
  ' "$charter" >"$tmp" && mv "$tmp" "$charter"
}

ctx_row() { # id -> one JSON row
  sql "SELECT json_object('id',id,'kind',kind,'key',key,'body',body,'status',status,'task',task_id,'sha',sha,
         'author',author,'supersedes',supersedes,'reviewNote',review_note,'createdAt',created_at,'updatedAt',updated_at)
       FROM context WHERE id=$(qi "$1");"
}

ctx_print() { # JSON array on stdin
  jq -r '.[] | "#\(.id) [\(.kind)] \(.key)  (\(.status)\(if .task then ", " + (.task[0:8]) else "" end)\(if .sha then " @" + .sha[0:8] else "" end))\n    \(.body | gsub("\n"; "\n    "))"'
}

ctx_add() {
  local kind="" key="" body="" task="" sha="" bcast=0
  while [[ $# -gt 0 ]]; do case "$1" in
    --kind) kind="$2"; shift 2;;  --key) key="$2"; shift 2;;
    --task) task="$2"; shift 2;;  --sha) sha="$2"; shift 2;;
    --broadcast) bcast=1; shift;;
    -*) die "ctx add: unknown option $1";;  *) body="$1"; shift;; esac; done
  [[ " $CTX_KINDS " == *" $kind "* ]] || die "ctx add: --kind must be one of: $CTX_KINDS"
  [[ -n "$key" ]] || die "ctx add: --key required (short, stable, e.g. auth/token-format)"
  [[ -n "$body" ]] || die "ctx add: body text required"
  [[ ${#body} -le 2000 ]] || die "ctx add: body over 2000 chars; keep entries short and link to files instead"
  local me="${CHIRP_SESSION_ID:-}" t
  if [[ -n "$task" ]]; then task="$(resolve_worker "$task")"
  elif [[ -n "$me" && "$me" != "$LEAD" ]]; then task="$me"; fi
  if [[ -z "$sha" && -n "$task" ]]; then
    sha="$(git -C "$(worktree_of "$task")" rev-parse HEAD 2>/dev/null || true)"
  fi
  t="$(now)"
  local id
  if is_lead_caller; then
    id="$(tx "
      UPDATE context SET status='superseded', updated_at=$(q "$t") WHERE key=$(q "$key") AND status='approved';
      INSERT INTO context(kind,key,body,task_id,sha,author,status,supersedes,created_at,updated_at)
        VALUES ($(q "$kind"),$(q "$key"),$(q "$body"),$(qn "$task"),$(qn "$sha"),$(qn "${me:-human}"),'approved',
                (SELECT max(id) FROM context WHERE key=$(q "$key") AND status='superseded'),$(q "$t"),$(q "$t"));
      SELECT last_insert_rowid();")"
    render_charter
    echo "approved #$id [$kind] $key"
    if [[ $bcast -eq 1 ]]; then cmd_broadcast --fyi "Shared context updated: [$kind] $key -- $body (charter: $STATE_ROOT/$LEAD/charter.md)"; fi
  else
    id="$(tx "
      INSERT INTO context(kind,key,body,task_id,sha,author,status,created_at,updated_at)
        VALUES ($(q "$kind"),$(q "$key"),$(q "$body"),$(qn "$task"),$(qn "$sha"),$(q "$me"),'proposed',$(q "$t"),$(q "$t"));
      SELECT last_insert_rowid();")"
    "$XIRP" session message "$LEAD" "[WORKER PROPOSAL] ctx #$id [$kind] $key: $body  (approve: hierarchy.sh ctx approve $id)" \
      --from "$me" >/dev/null 2>&1 || warn "could not notify lead"
    echo "proposed #$id [$kind] $key; the lead must approve it before it is binding"
  fi
}

ctx_review() { # approve|reject id [note]
  local action="$1" id note="${3:-}" row st key t
  require_lead "$action context entries"
  id="$(qi "${2:-}")"; row="$(ctx_row "$id")"
  [[ -n "$row" ]] || die "no context entry #$id"
  st="$(jq -r .status <<<"$row")"; key="$(jq -r .key <<<"$row")"; t="$(now)"
  [[ "$st" == "proposed" ]] || die "#$id is $st, not proposed"
  if [[ "$action" == "approve" ]]; then
    tx "UPDATE context SET status='superseded', updated_at=$(q "$t") WHERE key=$(q "$key") AND status='approved';
        UPDATE context SET status='approved', review_note=$(qn "$note"), updated_at=$(q "$t"),
          supersedes=(SELECT max(id) FROM context WHERE key=$(q "$key") AND status='superseded')
        WHERE id=$id;"
    render_charter
    echo "approved #$id $key"
  else
    tx "UPDATE context SET status='rejected', review_note=$(qn "$note"), updated_at=$(q "$t") WHERE id=$id;"
    echo "rejected #$id $key"
  fi
  local task; task="$(jq -r '.task // empty' <<<"$row")"
  if [[ -n "$task" && "$task" != "$LEAD" ]]; then
    msg "$task" "[LEAD FYI] Context proposal #$id ($key) ${action}d${note:+: $note}.$FYI_SUFFIX"
  fi
}

ctx_list() {
  local where="status='approved'" lim=100
  while [[ $# -gt 0 ]]; do case "$1" in
    --proposed) where="status='proposed'"; shift;;  --all) where="1=1"; shift;;
    --kind) where="$where AND kind=$(q "$2")"; shift 2;;
    --limit) lim="$(qi "$2")"; shift 2;;
    *) die "ctx list: unknown option $1";; esac; done
  sql "SELECT json_group_array(json(r)) FROM (SELECT json_object('id',id,'kind',kind,'key',key,'body',body,
         'status',status,'task',task_id,'sha',sha) AS r FROM context WHERE $where ORDER BY id LIMIT $lim);" | ctx_print
}

ctx_search() {
  local query="" lim=5 inc=""
  while [[ $# -gt 0 ]]; do case "$1" in
    --limit) lim="$(qi "$2")"; shift 2;;  --include-proposed) inc=",'proposed'"; shift;;
    -*) die "ctx search: unknown option $1";;  *) query="$1"; shift;; esac; done
  [[ -n "$query" ]] || die "usage: ctx search \"words\" [--limit 5]"
  [[ $lim -le 20 ]] || lim=20
  local rows
  if has_fts; then
    # quote each word so user input can't inject FTS syntax; OR them and rank by bm25
    local m; m="$(tr -cs '[:alnum:]_' '\n' <<<"$query" | sed '/^$/d; s/.*/"&"/' | paste -sd' ' - | sed 's/" "/" OR "/g')"
    [[ -n "$m" ]] || die "ctx search: no searchable words"
    rows="$(sql "SELECT json_group_array(json(r)) FROM (SELECT json_object('id',c.id,'kind',c.kind,'key',c.key,'body',c.body,
              'status',c.status,'task',c.task_id,'sha',c.sha) AS r
            FROM context_fts f JOIN context c ON c.id=f.rowid
            WHERE context_fts MATCH $(q "$m") AND c.status IN ('approved'$inc)
            ORDER BY bm25(context_fts, 2.0, 1.0) LIMIT $lim);")"
  else
    rows="$(sql "SELECT json_group_array(json(r)) FROM (SELECT json_object('id',id,'kind',kind,'key',key,'body',body,
              'status',status,'task',task_id,'sha',sha) AS r FROM context
            WHERE (key LIKE $(q "%$query%") OR body LIKE $(q "%$query%")) AND status IN ('approved'$inc)
            ORDER BY id DESC LIMIT $lim);")"
  fi
  if [[ "$(jq length <<<"$rows")" == "0" ]]; then echo "no matches"; else ctx_print <<<"$rows"; fi
}

ctx_get() {
  [[ -n "${1:-}" ]] || die "usage: ctx get <key|#id>"
  local where
  if [[ "$1" =~ ^#?[0-9]+$ ]]; then where="id=${1#\#}"; else where="key=$(q "$1") AND status='approved'"; fi
  local r; r="$(sql "SELECT json_group_array(json(r)) FROM (SELECT json_object('id',id,'kind',kind,'key',key,'body',body,
              'status',status,'task',task_id,'sha',sha) AS r FROM context WHERE $where);")"
  if [[ "$(jq length <<<"$r")" == "0" ]]; then die "no approved entry for '$1'"; fi
  ctx_print <<<"$r"
}

cmd_ctx() {
  local sub="${1:-}"; shift || true
  if [[ "${1:-}" == "--lead" ]]; then LEAD="$2"; shift 2; fi
  LEAD="$(resolve_lead "$LEAD")"
  case "$sub" in
    add) ctx_add "$@";;
    approve|reject) ctx_review "$sub" "$@";;
    list) ctx_list "$@";;
    search) ctx_search "$@";;
    get) ctx_get "$@";;
    render) require_lead "render the charter"; render_charter; echo "rendered $STATE_ROOT/$LEAD/charter.md";;
    *) die "usage: ctx add|approve|reject|list|search|get|render (see help)";;
  esac
}
