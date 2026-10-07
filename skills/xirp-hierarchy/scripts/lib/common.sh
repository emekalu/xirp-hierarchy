# shellcheck shell=bash
# Shared helpers: errors, SQLite state, xirp and git queries.

# task states that consume a worker slot
ACTIVE='["spawned","working","question","blocked","ready","reviewing","changes_requested"]'
# task states that still own their files
OWNING='["spawned","working","question","blocked","ready","reviewing","changes_requested","accepted"]'
ACTIVE_SQL="'spawned','working','question','blocked','ready','reviewing','changes_requested'"

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
now()  { date -u +%FT%TZ; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed"; }

need jq; need git; need sqlite3
[[ -x "$XIRP" ]] || die "xirp CLI not found at $XIRP (set XIRP_BIN to override)"

# ---------------------------------------------------------------- SQLite state
#
# One database per hierarchy: $STATE_ROOT/<lead>/state.db (WAL mode).
# Every multi-statement change runs inside BEGIN IMMEDIATE ... COMMIT, so concurrent
# workers serialise on SQLite's write lock instead of overwriting each other.

db_path()   { echo "$STATE_ROOT/$1/state.db"; }
has_state() { [[ -f "$(db_path "$1")" ]]; }

# q <text> -> SQL string literal; qn -> NULL when empty; qi -> integer or die
q()  { local sq="'"; local s="${1//$sq/$sq$sq}"; printf "'%s'" "$s"; }
qn() { if [[ -z "${1:-}" ]]; then printf 'NULL'; else q "$1"; fi; }
qi() { [[ "$1" =~ ^-?[0-9]+$ ]] || die "not an integer: '$1'"; printf '%s' "$1"; }
qf() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "not a number: '$1'"; printf '%s' "$1"; }

# sql_on <db-file> <sql>  — runs with a busy timeout; fails on first error
sql_on() {
  printf '.timeout %s\nPRAGMA foreign_keys=ON;\n%s\n' "${XIRP_HIERARCHY_BUSY_MS:-30000}" "$2" \
    | sqlite3 -bail -batch -noheader "$1"
}
sql() { has_state "$LEAD" || die "no state for lead $LEAD (run init)"; sql_on "$(db_path "$LEAD")" "$1"; }
tx()  { sql "BEGIN IMMEDIATE;
$1
COMMIT;"; }

SCHEMA_SQL="
CREATE TABLE hierarchy (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  lead TEXT NOT NULL, base_branch TEXT NOT NULL, project TEXT, test_command TEXT,
  max_workers INTEGER NOT NULL, max_minutes INTEGER NOT NULL, max_cost REAL NOT NULL,
  status TEXT NOT NULL DEFAULT 'active', created_at TEXT NOT NULL, finished_at TEXT);
CREATE TABLE tasks (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE, name TEXT NOT NULL UNIQUE, branch TEXT NOT NULL, base TEXT NOT NULL,
  owns TEXT NOT NULL CHECK (json_valid(owns) AND json_array_length(owns) > 0),
  goal TEXT NOT NULL, after_id TEXT, worktree_path TEXT,
  status TEXT NOT NULL, cancel_reason TEXT,
  acceptance TEXT CHECK (acceptance IS NULL OR json_valid(acceptance)),
  integration TEXT CHECK (integration IS NULL OR json_valid(integration)),
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE reports (
  id INTEGER PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id),
  kind TEXT NOT NULL, text TEXT NOT NULL, sha TEXT, at TEXT NOT NULL);
CREATE TABLE verifications (
  id INTEGER PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id),
  sha TEXT NOT NULL, command TEXT NOT NULL, exit_code INTEGER NOT NULL,
  clean INTEGER NOT NULL, consistent INTEGER NOT NULL,
  started_at TEXT NOT NULL, finished_at TEXT NOT NULL, log TEXT NOT NULL);
CREATE TABLE reviews (
  id INTEGER PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id),
  result TEXT NOT NULL, sha TEXT, note TEXT, at TEXT NOT NULL);
CREATE TABLE invalidations (
  id INTEGER PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id),
  acceptance TEXT NOT NULL, reason TEXT NOT NULL, at TEXT NOT NULL);
CREATE TABLE integration_runs (
  id INTEGER PRIMARY KEY, sha TEXT NOT NULL, command TEXT NOT NULL, exit_code INTEGER NOT NULL,
  started_at TEXT NOT NULL, finished_at TEXT NOT NULL, log TEXT NOT NULL);
CREATE TABLE context (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('decision','interface','gotcha','finding','note')),
  key TEXT NOT NULL, body TEXT NOT NULL,
  task_id TEXT, sha TEXT, author TEXT,
  status TEXT NOT NULL CHECK (status IN ('proposed','approved','superseded','rejected')),
  supersedes INTEGER REFERENCES context(id), review_note TEXT,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE UNIQUE INDEX context_one_approved_per_key ON context(key) WHERE status = 'approved';
"
FTS_SQL="
CREATE VIRTUAL TABLE context_fts USING fts5(key, body, content='context', content_rowid='id');
CREATE TRIGGER context_ai AFTER INSERT ON context BEGIN
  INSERT INTO context_fts(rowid, key, body) VALUES (new.id, new.key, new.body); END;
CREATE TRIGGER context_ad AFTER DELETE ON context BEGIN
  INSERT INTO context_fts(context_fts, rowid, key, body) VALUES ('delete', old.id, old.key, old.body); END;
CREATE TRIGGER context_au AFTER UPDATE OF key, body ON context BEGIN
  INSERT INTO context_fts(context_fts, rowid, key, body) VALUES ('delete', old.id, old.key, old.body);
  INSERT INTO context_fts(rowid, key, body) VALUES (new.id, new.key, new.body); END;
"

has_fts() { [[ "$(sql "SELECT count(*) FROM sqlite_master WHERE name='context_fts';")" == "1" ]]; }

# Whole hierarchy as one JSON document (same shape the jq-based readers expect).
DOC_SQL="
SELECT json_object(
  'version', 3, 'lead', h.lead, 'baseBranch', h.base_branch, 'project', h.project,
  'testCommand', h.test_command,
  'limits', json_object('maxWorkers', h.max_workers, 'maxMinutes', h.max_minutes, 'maxCostUsd', h.max_cost),
  'status', h.status, 'createdAt', h.created_at, 'finishedAt', h.finished_at,
  'tasks', (SELECT json_group_array(json(x)) FROM (SELECT json_object(
      'id', t.id, 'name', t.name, 'branch', t.branch, 'base', t.base, 'owns', json(t.owns),
      'goal', t.goal, 'after', t.after_id, 'worktreePath', t.worktree_path, 'status', t.status,
      'cancelReason', t.cancel_reason, 'createdAt', t.created_at, 'updatedAt', t.updated_at,
      'acceptance', json(t.acceptance), 'integration', json(t.integration),
      'reports', (SELECT json_group_array(json(y)) FROM (SELECT json_object(
          'kind', kind, 'text', text, 'sha', sha, 'at', at) AS y
          FROM reports WHERE task_id = t.id ORDER BY id)),
      'verifications', (SELECT json_group_array(json(y)) FROM (SELECT json_object(
          'sha', sha, 'command', command, 'exitCode', exit_code,
          'clean', json(CASE WHEN clean THEN 'true' ELSE 'false' END),
          'consistent', json(CASE WHEN consistent THEN 'true' ELSE 'false' END),
          'startedAt', started_at, 'finishedAt', finished_at, 'log', log) AS y
          FROM verifications WHERE task_id = t.id ORDER BY id)),
      'reviews', (SELECT json_group_array(json(y)) FROM (SELECT json_object(
          'result', result, 'sha', sha, 'note', note, 'at', at) AS y
          FROM reviews WHERE task_id = t.id ORDER BY id)),
      'invalidated', (SELECT json_group_array(json(y)) FROM (SELECT
          json_set(acceptance, '$.invalidatedAt', at, '$.reason', reason) AS y
          FROM invalidations WHERE task_id = t.id ORDER BY id))
    ) AS x FROM tasks t ORDER BY t.seq)),
  'integrationRuns', (SELECT json_group_array(json(x)) FROM (SELECT json_object(
      'sha', sha, 'command', command, 'exitCode', exit_code, 'startedAt', started_at,
      'finishedAt', finished_at, 'log', log) AS x FROM integration_runs ORDER BY id))
) FROM hierarchy h WHERE h.id = 1;"

state()     { sql "$DOC_SQL" | jq "$@"; }
task_json() { state -c --arg id "$1" '.tasks[] | select(.id==$id)'; }

# ---------------------------------------------------------------- xirp

session_json() { "$XIRP" session get "$1" --json; }
tags_of() { jq -r '(.tags // []) | .[] | if type=="object" then "\(.key):\(.value)" else . end' <<<"$1"; }

resolve_lead() {
  local explicit="${1:-}" me parent
  if [[ -n "$explicit" ]]; then echo "$explicit"; return; fi
  if [[ -n "${XIRP_HIERARCHY_LEAD:-}" ]]; then echo "$XIRP_HIERARCHY_LEAD"; return; fi
  me="${CHIRP_SESSION_ID:-}"
  if [[ -n "$me" ]]; then
    if has_state "$me"; then echo "$me"; return; fi
    parent="$(session_json "$me" | jq -r '.parentSessionId // empty')"
    if [[ -n "$parent" ]] && has_state "$parent"; then echo "$parent"; return; fi
  fi
  die "cannot determine lead session; run 'init' in the lead session or pass --lead <id>"
}

# true when the caller acts with lead authority (the lead session, or a human outside any session)
is_lead_caller() { [[ -z "${CHIRP_SESSION_ID:-}" || "${CHIRP_SESSION_ID:-}" == "$LEAD" ]]; }
require_lead()   { is_lead_caller || die "only the lead session may $1"; }

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

# dirty    = anything uncommitted, incl. untracked files (used for deletion safety)
# modified = tracked changes only (used for review gates; untracked test artefacts are not part of a SHA)
wt_facts() { # wt base -> {exists, head, dirty, modified, untracked, ahead, merged}
  local wt="$1" base="$2" b merged
  if [[ -z "$wt" || ! -d "$wt" ]]; then echo '{"exists":false}'; return; fi
  b="$(base_ref "$wt" "$base")"
  if git -C "$wt" merge-base --is-ancestor HEAD "$b"; then merged=true; else merged=false; fi
  jq -nc --arg head "$(git -C "$wt" rev-parse HEAD)" \
        --arg dirty "$(git -C "$wt" status --porcelain)" \
        --arg mod "$(git -C "$wt" status --porcelain --untracked-files=no)" \
        --arg untr "$(git -C "$wt" ls-files --others --exclude-standard | head -n 20)" \
        --arg ahead "$(git -C "$wt" rev-list --count "$b..HEAD")" \
        --argjson merged "$merged" \
        '{exists:true, head:$head, dirty:($dirty!=""), modified:($mod!=""),
          untracked:($untr|split("\n")|map(select(.!=""))), ahead:($ahead|tonumber), merged:$merged}'
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
