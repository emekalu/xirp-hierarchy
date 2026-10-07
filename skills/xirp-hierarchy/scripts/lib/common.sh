# shellcheck shell=bash
# Shared helpers: errors, locking, state I/O, xirp and git queries.

# task states that consume a worker slot
ACTIVE='["spawned","working","question","blocked","ready","reviewing","changes_requested"]'
# task states that still own their files
OWNING='["spawned","working","question","blocked","ready","reviewing","changes_requested","accepted"]'

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
now()  { date -u +%FT%TZ; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed"; }

need jq; need git
[[ -x "$XIRP" ]] || die "xirp CLI not found at $XIRP (set XIRP_BIN to override)"

# ---------------------------------------------------------------- locking + state

locked() { # lockfile cmd...
  local lf="$1"; shift
  if command -v flock >/dev/null 2>&1; then
    flock -w "${XIRP_HIERARCHY_LOCK_TIMEOUT:-30}" "$lf" "$@"
  else
    need perl
    # $^F is raised before open() so the locked fd survives exec into the command.
    perl -MFcntl=:flock -e '
      $^F = 1023; my $lf = shift; my $t = $ENV{XIRP_HIERARCHY_LOCK_TIMEOUT} || 30;
      open(my $fh, ">>", $lf) or die "lock $lf: $!\n";
      my $s = time;
      until (flock($fh, LOCK_EX | LOCK_NB)) {
        die "timed out waiting for lock $lf\n" if time - $s > $t;
        select(undef, undef, undef, 0.05);
      }
      exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n";' "$lf" "$@"
  fi
}

tasks_file() { echo "$STATE_ROOT/$1/tasks.json"; }

# tasks_update <lead> <jq args...> — locked, validated, atomic replace
tasks_update() {
  local tf; tf="$(tasks_file "$1")"; shift
  [[ -f "$tf" ]] || die "no state file $tf (run init)"
  locked "$tf.lock" bash "$SELF" __apply "$tf" "$@"
}

cmd___apply() { # internal; runs while holding the lock
  local tf="$1"; shift
  local before tmp
  before="$(jq '.tasks | length' "$tf")"
  tmp="$(mktemp "$tf.tmp.XXXXXX")"
  if ! jq "$@" "$tf" >"$tmp"; then rm -f "$tmp"; die "state update failed (jq error)"; fi
  if ! jq -e --argjson n "$before" \
      'type=="object" and (.tasks|type=="array") and (.tasks|length) >= $n
       and all(.tasks[]; (.id|type)=="string")' "$tmp" >/dev/null; then
    rm -f "$tmp"; die "state update would lose or corrupt tasks; nothing written"
  fi
  mv "$tmp" "$tf"
}

state()     { jq "$@" "$(tasks_file "$LEAD")"; }
task_json() { jq -c --arg id "$1" '.tasks[] | select(.id==$id)' "$(tasks_file "$LEAD")"; }

# ---------------------------------------------------------------- xirp

session_json() { "$XIRP" session get "$1" --json; }
tags_of() { jq -r '(.tags // []) | .[] | if type=="object" then "\(.key):\(.value)" else . end' <<<"$1"; }

resolve_lead() {
  local explicit="${1:-}" me parent
  if [[ -n "$explicit" ]]; then echo "$explicit"; return; fi
  if [[ -n "${XIRP_HIERARCHY_LEAD:-}" ]]; then echo "$XIRP_HIERARCHY_LEAD"; return; fi
  me="${CHIRP_SESSION_ID:-}"
  if [[ -n "$me" ]]; then
    if [[ -f "$STATE_ROOT/$me/tasks.json" ]]; then echo "$me"; return; fi
    parent="$(session_json "$me" | jq -r '.parentSessionId // empty')"
    if [[ -n "$parent" && -f "$STATE_ROOT/$parent/tasks.json" ]]; then echo "$parent"; return; fi
  fi
  die "cannot determine lead session; run 'init' in the lead session or pass --lead <id>"
}

resolve_worker() { # ref -> id
  local id
  id="$(state -r --arg r "$1" '.tasks[] | select(.name==$r or .branch==$r or (.id|startswith($r))) | .id' | head -n1)"
  [[ -n "$id" ]] || die "no worker matching '$1' (use name, branch, or id prefix; see 'status')"
  echo "$id"
}

worktree_of() { # id -> path ('' if unknown)
  local wt
  wt="$(session_json "$1" 2>/dev/null | jq -r '.worktreePath // empty' || true)"
  [[ -n "$wt" ]] || wt="$(task_json "$1" | jq -r '.worktreePath // empty')"
  echo "$wt"
}

msg() { # to text
  "$XIRP" session message "$1" "$2" --from "$LEAD" >/dev/null 2>&1 || warn "could not message ${1:0:8}"
}

# ---------------------------------------------------------------- git

base_ref() { # repo-dir base -> ref
  if git -C "$1" rev-parse --verify -q "refs/heads/$2" >/dev/null; then echo "$2"
  elif git -C "$1" rev-parse --verify -q "refs/remotes/origin/$2" >/dev/null; then echo "origin/$2"
  else die "base branch '$2' not found from $1"; fi
}

wt_facts() { # wt base -> {exists, head, dirty, ahead, merged}
  local wt="$1" base="$2" b merged
  if [[ -z "$wt" || ! -d "$wt" ]]; then echo '{"exists":false}'; return; fi
  b="$(base_ref "$wt" "$base")"
  if git -C "$wt" merge-base --is-ancestor HEAD "$b"; then merged=true; else merged=false; fi
  jq -nc --arg head "$(git -C "$wt" rev-parse HEAD)" \
        --arg dirty "$(git -C "$wt" status --porcelain)" \
        --arg ahead "$(git -C "$wt" rev-list --count "$b..HEAD")" \
        --argjson merged "$merged" \
        '{exists:true, head:$head, dirty:($dirty!=""), ahead:($ahead|tonumber), merged:$merged}'
}

changed_files() { # wt base
  local b; b="$(base_ref "$1" "$2")"
  git -C "$1" diff --name-only "$(git -C "$1" merge-base "$b" HEAD)" HEAD
}

norm_path() { local p="${1#./}"; p="${p%/}"; [[ -n "$p" ]] || p="."; echo "$p"; }
path_under() { # file prefix
  local f p; f="$(norm_path "$1")"; p="$(norm_path "$2")"
  [[ "$p" == "." || "$f" == "$p" || "$f" == "$p/"* ]]
}

scope_violations() { # id wt base -> out-of-scope files, one per line
  local id="$1" wt="$2" base="$3" f p ok owns
  owns="$(task_json "$id" | jq -r '.owns[]')"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    ok=0
    while IFS= read -r p; do
      if [[ -n "$p" ]] && path_under "$f" "$p"; then ok=1; break; fi
    done <<<"$owns"
    if [[ $ok -eq 0 ]]; then echo "$f"; fi
  done < <(changed_files "$wt" "$base")
}

render_template() { # file KEY=VALUE...
  local content kv k v; content="$(cat "$1")"; shift
  for kv in "$@"; do k="${kv%%=*}"; v="${kv#*=}"; content="${content//\{\{$k\}\}/$v}"; done
  printf '%s\n' "$content"
}

run_logged() { # dir log cmd -> exit code (never fails the caller)
  local rc=0
  ( cd "$1" && bash -c "$3" ) >"$2" 2>&1 || rc=$?
  echo "$rc"
}
