#!/usr/bin/env bash
# hierarchy.sh — lead/worker orchestration over xirp sessions.
# State: ~/.local/state/xirp-hierarchy/<lead-id>/{charter.md,tasks.json}
set -euo pipefail

XIRP="${XIRP_BIN:-$HOME/.local/bin/xirp}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_ROOT="${XIRP_HIERARCHY_STATE:-$HOME/.local/state/xirp-hierarchy}"

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed"; }
need jq
[[ -x "$XIRP" ]] || die "xirp CLI not found at $XIRP (set XIRP_BIN to override)"

# ---------- helpers ----------

session_json() { "$XIRP" session get "$1" --json; }

# tags may be ["k:v"] or [{key,value}] — normalise to "k:v" lines
tags_of() { jq -r '(.tags // []) | .[] | if type=="object" then "\(.key):\(.value)" else . end' <<<"$1"; }

# resolve LEAD id: --lead flag > $XIRP_HIERARCHY_LEAD > current session if it has a charter > parent of current session
resolve_lead() {
  local explicit="${1:-}"
  if [[ -n "$explicit" ]]; then echo "$explicit"; return; fi
  if [[ -n "${XIRP_HIERARCHY_LEAD:-}" ]]; then echo "$XIRP_HIERARCHY_LEAD"; return; fi
  local me="${CHIRP_SESSION_ID:-}"
  if [[ -n "$me" ]]; then
    if [[ -f "$STATE_ROOT/$me/charter.md" ]]; then echo "$me"; return; fi
    local parent
    parent="$(session_json "$me" | jq -r '.parentSessionId // empty')"
    if [[ -n "$parent" && -f "$STATE_ROOT/$parent/charter.md" ]]; then echo "$parent"; return; fi
  fi
  die "cannot determine lead session; run 'init' in the lead session or pass --lead <id>"
}

tasks_file() { echo "$STATE_ROOT/$1/tasks.json"; }

# find a worker by name, branch, or id prefix within a lead's tasks
resolve_worker() {
  local lead="$1" ref="$2" tf
  tf="$(tasks_file "$lead")"
  [[ -f "$tf" ]] || die "no tasks.json for lead $lead"
  local id
  id="$(jq -r --arg r "$ref" '
    .tasks[] | select(.name==$r or .branch==$r or (.id|startswith($r))) | .id' "$tf" | head -n1)"
  [[ -n "$id" ]] || die "no worker matching '$ref' (use name, branch, or id prefix; see 'status')"
  echo "$id"
}

set_task_status() {
  local lead="$1" id="$2" status="$3" tf
  tf="$(tasks_file "$lead")"
  tmp="$(mktemp)"
  jq --arg id "$id" --arg s "$status" --arg t "$(date -u +%FT%TZ)" \
    '(.tasks[] | select(.id==$id)) |= (.status=$s | .updatedAt=$t)' "$tf" >"$tmp" && mv "$tmp" "$tf"
}

render_template() { # file, then KEY=VALUE pairs
  local file="$1"; shift
  local content; content="$(cat "$file")"
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    content="${content//\{\{$k\}\}/$v}"
  done
  printf '%s\n' "$content"
}

project_default_branch() {
  # best effort: git symbolic-ref of origin/HEAD, else main
  git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true
}

# ---------- commands ----------

cmd_whoami() {
  local me="${CHIRP_SESSION_ID:-}"
  if [[ -z "$me" ]]; then echo "none (not inside a managed xirp session)"; return; fi
  if [[ -f "$STATE_ROOT/$me/charter.md" ]]; then echo "lead $me"; return; fi
  local sj parent goal
  sj="$(session_json "$me")"
  parent="$(jq -r '.parentSessionId // empty' <<<"$sj")"
  goal="$(jq -r '.goal // ""' <<<"$sj")"
  if [[ -n "$parent" && -f "$STATE_ROOT/$parent/charter.md" ]] || grep -q 'XIRP-HIERARCHY WORKER BRIEF' <<<"$goal"; then
    echo "worker $me (lead: ${parent:-unknown})"; return
  fi
  echo "none $me"
}

cmd_init() {
  local lead="${CHIRP_SESSION_ID:-}" base="" project="" force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lead) lead="$2"; shift 2;;
      --base-branch) base="$2"; shift 2;;
      --project) project="$2"; shift 2;;
      --force) force=1; shift;;
      *) die "init: unknown option $1";;
    esac
  done
  [[ -n "$lead" ]] || die "init must run inside the lead session (or pass --lead <id>)"
  local dir="$STATE_ROOT/$lead"
  if [[ -f "$dir/charter.md" && $force -eq 0 ]]; then
    echo "charter already exists: $dir/charter.md (use --force to overwrite)"; return
  fi
  mkdir -p "$dir"
  [[ -n "$project" ]] || project="${CHIRP_PROJECT_ID:-$(pwd)}"
  [[ -n "$base" ]] || base="$(project_default_branch)"
  [[ -n "$base" ]] || base="main"
  render_template "$SKILL_DIR/assets/charter-template.md" \
    "LEAD_ID=$lead" "PROJECT=$project" "BASE_BRANCH=$base" "CREATED_AT=$(date -u +%FT%TZ)" \
    >"$dir/charter.md"
  jq -n --arg lead "$lead" --arg base "$base" --arg project "$project" --arg t "$(date -u +%FT%TZ)" \
    '{lead:$lead, baseBranch:$base, project:$project, createdAt:$t, status:"active", tasks:[]}' \
    >"$dir/tasks.json"
  local cur; cur="$(session_json "$lead" | jq -r '.name // ""')"
  [[ "$cur" == LEAD:* ]] || "$XIRP" session update "$lead" --name "LEAD: $cur" >/dev/null 2>&1 || true
  echo "lead:    $lead"
  echo "charter: $dir/charter.md"
  echo "next:    edit the charter (objective, conventions, test command, deploy), then 'spawn' workers"
}

cmd_spawn() {
  local lead="" name="" branch="" goal="" after="" base="" foreground=0 extra=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lead) lead="$2"; shift 2;;
      --name) name="$2"; shift 2;;
      --branch) branch="$2"; shift 2;;
      --goal) goal="$2"; shift 2;;
      --after) after="$2"; shift 2;;
      --base-branch) base="$2"; shift 2;;
      --foreground) foreground=1; shift;;
      --harness|--model|--profile|--project) extra+=("$1" "$2"); shift 2;;
      --auto-mode|--no-terminal) extra+=("$1"); shift;;
      *) die "spawn: unknown option $1";;
    esac
  done
  lead="$(resolve_lead "$lead")"
  [[ -n "$name" ]] || die "spawn: --name required"
  [[ -n "$goal" ]] || die "spawn: --goal required"
  local dir="$STATE_ROOT/$lead" tf; tf="$(tasks_file "$lead")"
  [[ -f "$dir/charter.md" ]] || die "no charter for lead $lead; run init first"
  [[ -n "$base" ]] || base="$(jq -r '.baseBranch' "$tf")"
  if [[ -z "$branch" ]]; then
    branch="hier/$(tr '[:upper:] ' '[:lower:]-' <<<"$name" | tr -cd 'a-z0-9-' | cut -c1-40)"
  fi

  local brief
  brief="$(render_template "$SKILL_DIR/assets/worker-brief.md" \
    "LEAD_ID=$lead" "TASK_NAME=$name" "CHARTER_PATH=$dir/charter.md" "SKILL_DIR=$SKILL_DIR" "GOAL=$goal")"

  local args=(session new --goal "$brief" --name "W: $name" --new-branch "$branch" --base-branch "$base"
              --parent "$lead" --tag "role:worker" --tag "lead:$lead" --json)
  if [[ -n "$after" ]]; then
    # --after accepts a worker name/branch/id-prefix from tasks.json, or any session id/branch
    local dep="$after"
    if [[ -f "$tf" ]]; then
      dep="$(jq -r --arg r "$after" '.tasks[] | select(.name==$r or .branch==$r or (.id|startswith($r))) | .id' "$tf" | head -n1)"
      [[ -n "$dep" ]] || dep="$after"
    fi
    args+=(--depends-on "$dep")
  fi
  [[ $foreground -eq 1 ]] && args+=(--foreground)
  args+=("${extra[@]}")

  local out id
  out="$("$XIRP" "${args[@]}")"
  id="$(jq -r '.id // .session.id // empty' <<<"$out")"
  [[ -n "$id" ]] || { echo "$out"; die "could not read new session id from xirp output"; }

  local tmp; tmp="$(mktemp)"
  jq --arg id "$id" --arg name "$name" --arg branch "$branch" --arg goal "$goal" --arg after "$after" \
     --arg t "$(date -u +%FT%TZ)" \
     '.tasks += [{id:$id, name:$name, branch:$branch, goal:$goal, after:($after|select(.!="")), status:"spawned", createdAt:$t, updatedAt:$t}]' \
     "$tf" >"$tmp" && mv "$tmp" "$tf"
  echo "spawned worker: $name"
  echo "  session: $id"
  echo "  branch:  $branch (from $base)"
  [[ -n "$after" ]] && echo "  queued after: $after"
  echo "remember to add this task to the charter's task table: $dir/charter.md"
}

cmd_status() {
  local lead=""
  [[ "${1:-}" == "--lead" ]] && lead="$2"
  lead="$(resolve_lead "$lead")"
  local tf; tf="$(tasks_file "$lead")"
  echo "lead: $lead   charter: $STATE_ROOT/$lead/charter.md"
  printf '%-10s %-34s %-28s %-11s %-11s %s\n' ID NAME BRANCH SESSION TASK LAST_MESSAGE
  jq -r '.tasks[] | [.id, .name, .branch, .status] | @tsv' "$tf" | while IFS=$'\t' read -r id name branch tstatus; do
    local sj sstatus last
    sj="$(session_json "$id" 2>/dev/null || echo '{}')"
    sstatus="$(jq -r '.status // "?"' <<<"$sj")"
    last="$(jq -r '(.lastUserMessage // "") | gsub("\n";" ") | .[0:60]' <<<"$sj")"
    printf '%-10s %-34s %-28s %-11s %-11s %s\n' "${id:0:8}" "${name:0:34}" "${branch:0:28}" "$sstatus" "$tstatus" "$last"
  done
}

cmd_tell() {
  local lead="" ; [[ "${1:-}" == "--lead" ]] && { lead="$2"; shift 2; }
  local ref="${1:-}" text="${2:-}"
  [[ -n "$ref" && -n "$text" ]] || die "usage: tell <worker> \"message\""
  lead="$(resolve_lead "$lead")"
  local id; id="$(resolve_worker "$lead" "$ref")"
  "$XIRP" session message "$id" "[LEAD] $text" --from "$lead"
  echo "sent to $ref ($id)"
}

cmd_broadcast() {
  local lead="" ; [[ "${1:-}" == "--lead" ]] && { lead="$2"; shift 2; }
  local text="${1:-}"; [[ -n "$text" ]] || die "usage: broadcast \"message\""
  lead="$(resolve_lead "$lead")"
  local tf; tf="$(tasks_file "$lead")"
  jq -r '.tasks[] | select(.status!="accepted" and .status!="done") | .id' "$tf" | while read -r id; do
    local st; st="$(session_json "$id" | jq -r '.status')"
    case "$st" in running|idle|waiting) "$XIRP" session message "$id" "[LEAD] $text" --from "$lead" && echo "sent to ${id:0:8}";;
      *) echo "skipped ${id:0:8} ($st)";; esac
  done
}

cmd_report() {
  # worker → lead
  local kind="${1:-}" text="${2:-}"
  case "$kind" in READY|QUESTION|BLOCKED|PROGRESS) ;; *) die "usage: report READY|QUESTION|BLOCKED|PROGRESS \"text\"";; esac
  [[ -n "$text" ]] || die "report: text required"
  local me="${CHIRP_SESSION_ID:-}"; [[ -n "$me" ]] || die "report must run inside a worker session"
  local sj lead name branch
  sj="$(session_json "$me")"
  lead="$(jq -r '.parentSessionId // empty' <<<"$sj")"
  [[ -n "$lead" ]] || lead="$(tags_of "$sj" | sed -n 's/^lead://p' | head -n1)"
  [[ -n "$lead" ]] || die "cannot find lead for this worker (no parentSessionId / lead: tag)"
  name="$(jq -r '.name // ""' <<<"$sj")"; branch="$(jq -r '.branch // ""' <<<"$sj")"
  "$XIRP" session message "$lead" "[WORKER $kind] ${name} (${me:0:8}, ${branch}): $text" --from "$me"
  # keep lead's tasks.json in sync when possible
  local tf; tf="$(tasks_file "$lead")"
  if [[ -f "$tf" ]]; then
    case "$kind" in READY) set_task_status "$lead" "$me" ready;; QUESTION) set_task_status "$lead" "$me" question;;
      BLOCKED) set_task_status "$lead" "$me" blocked;; PROGRESS) set_task_status "$lead" "$me" working;; esac
  fi
  echo "reported $kind to lead ${lead:0:8}"
}

cmd_review() {
  local lead="" ; [[ "${1:-}" == "--lead" ]] && { lead="$2"; shift 2; }
  local ref="${1:-}"; [[ -n "$ref" ]] || die "usage: review <worker>"
  lead="$(resolve_lead "$lead")"
  local id tf base sj wt branch
  id="$(resolve_worker "$lead" "$ref")"; tf="$(tasks_file "$lead")"
  base="$(jq -r '.baseBranch' "$tf")"
  sj="$(session_json "$id")"
  wt="$(jq -r '.worktreePath // empty' <<<"$sj")"; branch="$(jq -r '.branch // empty' <<<"$sj")"
  [[ -n "$wt" ]] || die "worker $id has no worktree path"
  echo "worker:   $(jq -r '.name' <<<"$sj") ($id)"
  echo "worktree: $wt"
  echo "branch:   $branch   base: $base"
  echo "---- git log ----"
  git -C "$wt" --no-pager log --oneline "$base..HEAD" 2>/dev/null || git -C "$wt" --no-pager log --oneline -n 20
  echo "---- uncommitted ----"
  git -C "$wt" status --short
  echo "---- diff vs $base (stat) ----"
  git -C "$wt" --no-pager diff --stat "$base...HEAD" 2>/dev/null || true
  echo
  echo "full diff:  git -C '$wt' diff $base...HEAD"
  echo "run tests:  (cd '$wt' && <charter test command>)"
  echo "then:       hierarchy.sh accept $ref   |   hierarchy.sh tell $ref \"fix ...\""
  set_task_status "$lead" "$id" reviewing
}

cmd_accept() {
  local lead="" ; [[ "${1:-}" == "--lead" ]] && { lead="$2"; shift 2; }
  local ref="${1:-}"; [[ -n "$ref" ]] || die "usage: accept <worker>"
  lead="$(resolve_lead "$lead")"
  local id; id="$(resolve_worker "$lead" "$ref")"
  set_task_status "$lead" "$id" accepted
  "$XIRP" session message "$id" "[LEAD] Accepted. Your branch will be integrated by the lead. Do not make further changes unless asked." --from "$lead" >/dev/null 2>&1 || true
  echo "accepted $ref ($id)"
}

cmd_inbox() {
  local lead="" ; [[ "${1:-}" == "--lead" ]] && { lead="$2"; shift 2; }
  lead="$(resolve_lead "$lead")"
  # Reports land in the lead's transcript. Best effort: pull messages via the daemon API.
  "$XIRP" api send messages:list --param "sessionId=$lead" --json 2>/dev/null \
    | jq -r '.. | objects | select(has("content")) | .content | strings | select(test("^\\[WORKER "))' 2>/dev/null \
    || echo "(messages:list unavailable — reports appear directly in the lead session transcript)"
}

cmd_finish() {
  local lead="" cleanup=0 delbranch=0
  while [[ $# -gt 0 ]]; do case "$1" in
    --lead) lead="$2"; shift 2;; --cleanup) cleanup=1; shift;; --delete-branches) delbranch=1; shift;;
    *) die "finish: unknown option $1";; esac; done
  lead="$(resolve_lead "$lead")"
  local tf; tf="$(tasks_file "$lead")"
  local tmp; tmp="$(mktemp)"
  jq --arg t "$(date -u +%FT%TZ)" '.status="done" | .finishedAt=$t' "$tf" >"$tmp" && mv "$tmp" "$tf"
  if [[ $cleanup -eq 1 ]]; then
    jq -r '.tasks[].id' "$tf" | while read -r id; do
      local args=(session delete "$id" --yes --delete-worktree)
      [[ $delbranch -eq 1 ]] && args+=(--delete-branch)
      "$XIRP" "${args[@]}" && echo "deleted ${id:0:8}" || echo "could not delete ${id:0:8}"
    done
  fi
  echo "hierarchy $lead marked done. state kept at $STATE_ROOT/$lead"
}

cmd_charter() { local lead=""; [[ "${1:-}" == "--lead" ]] && lead="$2"; lead="$(resolve_lead "$lead")"; echo "$STATE_ROOT/$lead/charter.md"; }

cmd_help() {
  cat <<EOF
hierarchy.sh — lead/worker orchestration over xirp sessions

Lead commands (run inside the lead session, or pass --lead <id>):
  init [--base-branch b] [--project p] [--force]   make this session the lead; write charter
  spawn --name N --goal G [--branch b] [--after W] [--base-branch b] [--foreground]
                                                   create a worker session with the brief prepended
  status                                           table of workers and their state
  inbox                                            worker reports found in the lead transcript
  tell <worker> "msg"                              message one worker (name | branch | id prefix)
  broadcast "msg"                                  message all active workers
  review <worker>                                  show log/diff/worktree path for a worker branch
  accept <worker>                                  mark worker's branch accepted, notify it
  finish [--cleanup] [--delete-branches]           mark hierarchy done; optionally remove workers
  charter                                          print charter path

Worker commands (run inside a worker session):
  report READY|QUESTION|BLOCKED|PROGRESS "text"   send a report to the lead

Either:
  whoami                                           lead | worker | none

State: $STATE_ROOT/<lead-id>/{charter.md,tasks.json}
EOF
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  whoami|init|spawn|status|tell|broadcast|report|review|accept|inbox|finish|charter|help) "cmd_$cmd" "$@";;
  *) die "unknown command '$cmd' (see help)";;
esac
