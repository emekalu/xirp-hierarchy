# shellcheck shell=bash
# Worker-side commands and role detection: whoami, report.

cmd_whoami() {
  local me="${CHIRP_SESSION_ID:-}" sj parent goal
  if [[ -z "$me" ]]; then echo "none (not inside a managed xirp session)"; return; fi
  if [[ -f "$STATE_ROOT/$me/tasks.json" ]]; then echo "lead $me"; return; fi
  sj="$(session_json "$me")"
  parent="$(jq -r '.parentSessionId // empty' <<<"$sj")"
  goal="$(jq -r '.goal // ""' <<<"$sj")"
  if [[ -n "$parent" && -f "$STATE_ROOT/$parent/tasks.json" ]] || grep -q 'XIRP-HIERARCHY WORKER BRIEF' <<<"$goal"; then
    echo "worker $me (lead: ${parent:-unknown})"; return
  fi
  echo "none $me"
}

cmd_report() {
  local kind="${1:-}" text="${2:-}" st
  case "$kind" in
    READY) st=ready;; QUESTION) st=question;; BLOCKED) st=blocked;; PROGRESS) st=working;;
    *) die "usage: report READY|QUESTION|BLOCKED|PROGRESS \"text\"";;
  esac
  [[ -n "$text" ]] || die "report: text required"
  local me="${CHIRP_SESSION_ID:-}"; [[ -n "$me" ]] || die "report must run inside a worker session"
  local sj name branch wt sha="" dirty=""
  sj="$(session_json "$me")"
  LEAD="$(jq -r '.parentSessionId // empty' <<<"$sj")"
  [[ -n "$LEAD" ]] || LEAD="$(tags_of "$sj" | sed -n 's/^lead://p' | head -n1)"
  [[ -n "$LEAD" ]] || die "cannot find lead for this worker (no parentSessionId / lead: tag)"
  name="$(jq -r '.name // ""' <<<"$sj")"; branch="$(jq -r '.branch // ""' <<<"$sj")"
  wt="$(jq -r '.worktreePath // empty' <<<"$sj")"
  [[ -n "$wt" ]] || wt="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$wt" && -d "$wt" ]]; then
    sha="$(git -C "$wt" rev-parse HEAD)"; dirty="$(git -C "$wt" status --porcelain)"
  fi

  if [[ "$kind" == "READY" ]]; then
    [[ -n "$sha" ]] || die "cannot locate your worktree to record the commit"
    [[ -z "$dirty" ]] || die "uncommitted changes; commit (or discard) everything before reporting READY"
  fi

  "$XIRP" session message "$LEAD" "[WORKER $kind] $name (${me:0:8}, $branch @ ${sha:0:8}): $text" --from "$me"

  if [[ -f "$(tasks_file "$LEAD")" ]]; then
    if ! state -e --arg id "$me" 'any(.tasks[]; .id==$id)' >/dev/null; then
      warn "this session is not registered in the lead's tasks.json; the lead must track it"
    else
      # Append report; a new SHA invalidates any prior acceptance.
      tasks_update "$LEAD" --arg id "$me" --arg k "$kind" --arg text "$text" --arg sha "$sha" --arg st "$st" --arg t "$(now)" \
        '(.tasks[] | select(.id==$id)) |= (
           .reports += [{kind:$k, text:$text, sha:$sha, at:$t}]
           | (if .acceptance != null and $sha != "" and .acceptance.sha != $sha
              then .invalidated += [.acceptance + {invalidatedAt:$t, reason:"worker reported new commit \($sha[0:12])"}]
                   | .acceptance = null
              else . end)
           | .status = (if .acceptance != null and (.status=="accepted" or .status=="integrated") then .status else $st end)
           | .updatedAt = $t)'
    fi
  fi
  echo "reported $kind to lead ${LEAD:0:8}"
}
