# shellcheck shell=bash
# Worker-side commands and role detection: whoami, report.

cmd_whoami() {
  local me="${CHIRP_SESSION_ID:-}" sj parent goal
  if [[ -z "$me" ]]; then echo "none (not inside a managed xirp session)"; return; fi
  if has_state "$me"; then echo "lead $me"; return; fi
  sj="$(session_json "$me")"
  parent="$(jq -r '.parentSessionId // empty' <<<"$sj")"
  goal="$(jq -r '.goal // ""' <<<"$sj")"
  if { [[ -n "$parent" ]] && has_state "$parent"; } || grep -q 'XIRP-HIERARCHY WORKER BRIEF' <<<"$goal"; then
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
    sha="$(git -C "$wt" rev-parse HEAD)"; dirty="$(git -C "$wt" status --porcelain --untracked-files=no)"
  fi

  if [[ "$kind" == "READY" ]]; then
    [[ -n "$sha" ]] || die "cannot locate your worktree to record the commit"
    [[ -z "$dirty" ]] || die "uncommitted changes to tracked files; commit (or discard) them before reporting READY"
    local untr; untr="$(git -C "$wt" ls-files --others --exclude-standard | head -n 10)"
    if [[ -n "$untr" ]]; then warn "untracked files are NOT part of your commit (git add them if they are source): $(echo $untr)"; fi
  fi

  "$XIRP" session message "$LEAD" "[WORKER $kind] $name (${me:0:8}, $branch @ ${sha:0:8}): $text" --from "$me"

  if has_state "$LEAD"; then
    if ! state -e --arg id "$me" 'any(.tasks[]; .id==$id)' >/dev/null; then
      warn "this session is not registered in the lead's state; the lead must track it"
    else
      # One transaction: append report; a different SHA invalidates any prior acceptance; set status.
      local t id; t="$(now)"; id="$(q "$me")"
      local moved="acceptance IS NOT NULL AND $(q "$sha") <> '' AND json_extract(acceptance,'\$.sha') <> $(q "$sha")"
      tx "INSERT INTO reports(task_id,kind,text,sha,at) VALUES ($id,$(q "$kind"),$(q "$text"),$(qn "$sha"),$(q "$t"));
          INSERT INTO invalidations(task_id,acceptance,reason,at)
            SELECT id, acceptance, 'worker reported new commit ' || substr($(q "$sha"),1,12), $(q "$t")
            FROM tasks WHERE id=$id AND $moved;
          UPDATE tasks SET acceptance=NULL WHERE id=$id AND $moved;
          UPDATE tasks SET updated_at=$(q "$t"),
            status = CASE WHEN status='cancelled' THEN status WHEN acceptance IS NOT NULL AND status IN ('accepted','integrated') THEN status ELSE $(q "$st") END
          WHERE id=$id;"
    fi
  fi
  echo "reported $kind to lead ${LEAD:0:8}"
}
