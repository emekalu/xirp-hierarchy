# shellcheck shell=bash
# Lead monitoring: wait (block until something needs the lead) and preflight (did every worker start?).

# Signature of everything that should wake the lead: task status, session status, flags.
monitor_signature() { # enriched-json -> compact string
  jq -c '[.[] | {id, status, sessionStatus, flags: (.flags | map(select(startswith("OVER_")|not)) )}]' <<<"$1"
}

# Max ids of worker-originated events (reports, context proposals). Ids only grow, so this is a
# monotonic read cursor; persisted per lead in wait.cursor.
event_cursor() {
  sql "SELECT COALESCE((SELECT max(id) FROM reports),0) || ' ' ||
              COALESCE((SELECT max(id) FROM context WHERE author IN (SELECT id FROM tasks)),0);"
}

print_events_since() { # report_id ctx_id
  sql "SELECT json_group_array(json(x)) FROM (SELECT json_object('name',t.name,'kind',r.kind,
          'sha',substr(COALESCE(r.sha,''),1,8),'at',r.at,'text',r.text) AS x
        FROM reports r JOIN tasks t ON t.id=r.task_id WHERE r.id > $(qi "$1") ORDER BY r.id);" |
    jq -r '(if length > 20 then "  ... \(length-20) older report(s) omitted (inbox --all)" else empty end), (.[-20:][] | "  \(.at)  [\(.kind)] \(.name) @\(.sha): \(.text)")'
  sql "SELECT json_group_array(json(x)) FROM (SELECT json_object('id',id,'kind',kind,'key',key,'body',body,'status',status) AS x
        FROM context WHERE author IN (SELECT id FROM tasks) AND id > $(qi "$2") ORDER BY id);" |
    jq -r '.[] | "  [PROPOSAL] ctx #\(.id) [\(.kind)] \(.key) (\(.status)): \(.body)"
                 + (if .status=="proposed" then "   -> ctx approve \(.id) | ctx reject \(.id)" else "" end)'
}

# Block until a worker reports/proposes, a task or session changes state, or a flag appears/clears.
cmd_wait() {
  local timeout=10 interval=20
  while [[ $# -gt 0 ]]; do case "$1" in
    --lead) LEAD="$2"; shift 2;;  --timeout) timeout="$2"; shift 2;;  --interval) interval="$2"; shift 2;;
    *) die "wait: unknown option $1";; esac; done
  [[ "$timeout" =~ ^[0-9]+$ && "$interval" =~ ^[0-9]+$ && $interval -ge 1 ]] || die "wait: --timeout (minutes) and --interval (seconds) must be integers"
  LEAD="$(resolve_lead "$LEAD")"; require_lead "run this command"
  local cfile="$STATE_ROOT/$LEAD/wait.cursor" cur seen sig0 sig data deadline reason=""
  seen="$(cat "$cfile" 2>/dev/null || echo "0 0")"
  if [[ "$(state -r --argjson a "$ACTIVE" '[.tasks[] | select(.status as $s | $a | index($s))] | length')" == "0" ]]; then
    echo "nothing to wait for: no active tasks"; return 0
  fi
  data="$(enriched_tasks)"; sig0="$(monitor_signature "$data")"
  deadline=$(( $(date +%s) + timeout * 60 ))
  while :; do
    cur="$(event_cursor)"
    if [[ "$cur" != "$seen" ]]; then reason="new worker events"; break; fi
    sig="$(monitor_signature "$data")"
    if [[ "$sig" != "$sig0" ]]; then reason="task, session or flag change"; break; fi
    if [[ $(date +%s) -ge $deadline ]]; then reason="timeout (${timeout}m), nothing new"; break; fi
    sleep "$interval"
    data="$(enriched_tasks)"
  done
  # save the cursor first: output may be cut short (| head, SIGPIPE) and events must not replay forever
  echo "$cur" >"$cfile"
  echo "wake: $reason"
  set -- $seen; print_events_since "$1" "$2"
  echo
  cmd_status
}

# After spawning: confirm every spawned worker actually started producing tokens.
cmd_preflight() {
  local wait_s=90
  while [[ $# -gt 0 ]]; do case "$1" in
    --lead) LEAD="$2"; shift 2;;  --wait) wait_s="$2"; shift 2;;
    *) die "preflight: unknown option $1";; esac; done
  [[ "$wait_s" =~ ^[0-9]+$ ]] || die "preflight: --wait must be seconds"
  LEAD="$(resolve_lead "$LEAD")"; require_lead "run this command"
  local deadline=$(( $(date +%s) + wait_s )) id t sj name pending tok tmx pane bad=0
  while :; do
    pending=""
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      sj="$(session_json "$id" 2>/dev/null || echo '{}')"
      tok="$(jq '(.inputTokens // 0) + (.outputTokens // 0)' <<<"$sj")"
      # queued behind --after, already reported, or producing tokens: fine
      if [[ "$tok" == "0" && "$(jq -r '.status // ""' <<<"$sj")" == "running" ]]; then pending+="$id"$'\n'; fi
    done < <(state -r '.tasks[] | select(.status=="spawned") | select((.reports|length)==0) | .id')
    [[ -n "$pending" && $(date +%s) -lt $deadline ]] || break
    sleep 10
  done
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    t="$(task_json "$id")"; name="$(jq -r .name <<<"$t")"
    if ! grep -qx "$id" <<<"$pending"; then echo "ok       $name"; continue; fi
    bad=1; echo "STALLED  $name (${id:0:8}): no tokens after ${wait_s}s"
    tmx="$(session_json "$id" 2>/dev/null | jq -r '.tmuxSession // empty')"
    if [[ -n "$tmx" ]] && command -v tmux >/dev/null 2>&1; then
      pane="$(tmux capture-pane -p -t "$tmx" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 8 || true)"
      if [[ -n "$pane" ]]; then
        printf '%s\n' "$pane" | sed 's/^/    | /'
        case "$pane" in
          *"MCP server"*) echo "    -> Claude Code MCP approval dialog (from a .mcp.json in the repo or a parent dir). Ask the user; Esc rejects all: tmux send-keys -t $tmx Escape";;
          *[Tt]rust*) echo "    -> folder trust dialog. Ask the user before answering it in: tmux attach -t $tmx";;
          *) echo "    -> inspect: tmux attach -t $tmx";;
        esac
      fi
    fi
  done < <(state -r '.tasks[] | select(.status=="spawned") | .id')
  [[ $bad -eq 0 ]] || die "preflight: some workers have not started (see above); fix before relying on wait/status"
  echo "preflight ok"
}
