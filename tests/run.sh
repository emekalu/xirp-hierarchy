#!/usr/bin/env bash
# Integration tests for hierarchy.sh against a mock xirp and a real git repo.
# Usage: tests/run.sh [bash-binary]   (e.g. tests/run.sh /bin/bash to check bash 3.2)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BASH_BIN="${1:-bash}"
H="$HERE/../skills/xirp-hierarchy/scripts/hierarchy.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export MOCK_DIR="$T/mock" MOCK_REPO="$T/repo" XIRP_BIN="$HERE/mock-xirp" XIRP_HIERARCHY_STATE="$T/state"
mkdir -p "$MOCK_DIR/sessions"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

pass=0 fail=0
ok()   { echo "  ok   $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL $1"; fail=$((fail+1)); }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
refuse() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d (should have failed)"; else ok "$d"; fi; }
h() { "$BASH_BIN" "$H" "$@"; }
st() { "$BASH_BIN" "$H" dump --lead "$LEAD_ID" | jq "$@"; }
DB() { sqlite3 "$XIRP_HIERARCHY_STATE/$LEAD_ID/state.db" "$1"; }
CH="$T/state/lead-0000-test/charter.md"
wt_of() { jq -r .worktreePath "$MOCK_DIR/sessions/$1.json"; }
commit_in() { (cd "$1" && mkdir -p "$(dirname "$2")" && echo "${3:-x}" >"$2" && git add -A && git commit -qm "edit $2"); }

# repo: tests fail iff a file named FAIL exists
git init -q -b main "$MOCK_REPO"
(cd "$MOCK_REPO" && echo init >README && git add . && git commit -qm init)

LEAD_ID="lead-0000-test"
echo '{"id":"lead-0000-test","name":"demo","status":"running","tags":[],"totalCostUsd":0}' >"$MOCK_DIR/sessions/$LEAD_ID.json"
export CHIRP_SESSION_ID="$LEAD_ID"
cd "$MOCK_REPO"

echo "init/config"
check "init" h init --base-branch main --test-cmd 'test ! -e FAIL' --max-workers 2
check "state has limits + test command" st -e '.limits.maxWorkers==2 and .testCommand=="test ! -e FAIL"'
check "whoami is lead" bash -c "$BASH_BIN '$H' whoami | grep -q '^lead'"
check "state.db in WAL mode" bash -c "[ \"\$(sqlite3 '$T/state/lead-0000-test/state.db' 'pragma journal_mode')\" = wal ]"
check "charter shows test command" grep -q 'test ! -e FAIL' "$CH"
check "config updates charter" bash -c "$BASH_BIN '$H' config --max-cost 7 >/dev/null && grep -q 'minutes, \\\$7' '$CH'"

echo "spawn + registration (bug 1)"
check "spawn without --after" h spawn --name api --goal "do api" --owns src/api
check "task without --after is recorded" st -e '.tasks|length==1 and .[0].after==null and .[0].name=="api"'
refuse "overlapping ownership refused" h spawn --name api2 --goal g --owns src/api/v2
check "overlap allowed when sequenced --after owner" h spawn --name api2 --goal g --owns src/api/v2 --after api
check "--after recorded" st -e '.tasks[1].after == .tasks[0].id'
check "worker created in hierarchy's project" bash -c "[ \"\$(jq -r .project \"$MOCK_DIR/sessions/\$($BASH_BIN '$H' dump | jq -r '.tasks[0].id').json\")\" = \"\$($BASH_BIN '$H' dump | jq -r .project)\" ]"
check "charter task table generated" grep -q '| 2 | api2 | `hier/api2` |' "$CH"
refuse "duplicate worker name refused" h spawn --name api --goal g --owns other --force
refuse "worker limit enforced (2)" h spawn --name ui --goal g --owns src/ui
refuse "spawn without --owns refused" h spawn --name x --goal g --force

API="$(st -r '.tasks[0].id')"; API2="$(st -r '.tasks[1].id')"
WT="$(wt_of "$API")"

echo "concurrent reports (bug 2)"
for i in $(seq 1 25); do ( CHIRP_SESSION_ID="$API"  h report PROGRESS "a$i" >/dev/null 2>&1 ) & done
for i in $(seq 1 25); do ( CHIRP_SESSION_ID="$API2" h report PROGRESS "b$i" >/dev/null 2>&1 ) & done
wait
check "all 50 concurrent reports recorded" st -e '([.tasks[].reports[]]|length)==50'
check "state still valid JSON with 2 tasks" st -e '.tasks|length==2'
refuse "worker cannot accept" env CHIRP_SESSION_ID="$API" "$BASH_BIN" "$H" accept api
refuse "worker cannot spawn" env CHIRP_SESSION_ID="$API" "$BASH_BIN" "$H" spawn --name z --goal g --owns z

echo "shared context pool"
check "lead adds interface (approved)" h ctx add --kind interface --key auth/token "Tokens are JWT, header Authorization: Bearer, 15 min expiry"
check "lead adds decision" h ctx add --kind decision --key errors "Return RFC7807 problem+json on all API errors"
check "worker proposes gotcha" env CHIRP_SESSION_ID="$API" "$BASH_BIN" "$H" ctx add --kind gotcha --key db/migrations "Migrations must be idempotent; CI reruns them"
check "proposal recorded with task + sha" bash -c "[ \"\$(sqlite3 '$T/state/lead-0000-test/state.db' \"select status||':'||(task_id='$API')||':'||length(sha) from context where key='db/migrations'\")\" = 'proposed:1:40' ]"
check "lead notified of proposal" grep -q 'WORKER PROPOSAL' "$MOCK_DIR/messages.log"
check "proposal hidden from search" bash -c "$BASH_BIN '$H' ctx search idempotent | grep -q 'no matches'"
check "proposal not in charter" bash -c "! grep -q db/migrations '$CH'"
refuse "worker cannot approve" env CHIRP_SESSION_ID="$API2" "$BASH_BIN" "$H" ctx approve 3
check "lead approves" h ctx approve 3 "good catch"
check "approved entry searchable" bash -c "$BASH_BIN '$H' ctx search 'idempotent migrations' | grep -q db/migrations"
check "search ranks + limits" bash -c "[ \$($BASH_BIN '$H' ctx search 'token jwt errors' --limit 1 | grep -c '^#') -eq 1 ]"
check "search survives FTS syntax chars" h ctx search 'auth" OR (* NEAR'
check "charter has approved context" bash -c "grep -q 'auth/token' '$CH' && grep -q 'db/migrations' '$CH'"
check "re-adding key supersedes" h ctx add --kind interface --key auth/token "Tokens are JWT; 30 min expiry"
check "one approved per key, old superseded" bash -c "[ \"\$(sqlite3 '$T/state/lead-0000-test/state.db' \"select group_concat(status) from (select status from context where key='auth/token' order by id)\")\" = 'superseded,approved' ]"
check "charter shows only new version" bash -c "grep -q '30 min' '$CH' && ! grep -q '15 min' '$CH'"
check "ctx get by key" bash -c "$BASH_BIN '$H' ctx get auth/token | grep -q '30 min'"
check "sql injection in body stored literally" h ctx add --kind note --key "it's" "x'); DROP TABLE tasks; --"
check "tasks table intact" st -e '.tasks|length==2'
for i in $(seq 1 15); do ( CHIRP_SESSION_ID="$API" "$BASH_BIN" "$H" ctx add --kind finding --key "f$i" "finding $i" >/dev/null 2>&1 ) & done; wait
check "15 concurrent proposals recorded" bash -c "[ \$(sqlite3 '$T/state/lead-0000-test/state.db' \"select count(*) from context where key like 'f%' and status='proposed'\") -eq 15 ]"

echo "status flags"
OLD="$(date -u -v-10M +%FT%TZ 2>/dev/null || date -u -d '10 min ago' +%FT%TZ)"
DB "update tasks set created_at='$OLD' where name='api2'"
check "STALLED when no tokens after 3 min" bash -c "$BASH_BIN '$H' status --json | jq -e '.[]|select(.name==\"api2\")|.flags|index(\"STALLED\")'"
F="$MOCK_DIR/sessions/$(st -r '.tasks[1].id').json"; jq '.inputTokens=10|.outputTokens=5|.totalCostUsd=9' "$F" >"$F.tmp" && mv "$F.tmp" "$F"
check "not STALLED once tokens flow" bash -c "! $BASH_BIN '$H' status --json | jq -e '.[]|select(.name==\"api2\")|.flags|index(\"STALLED\")'"
check "OVER_COST flagged" bash -c "$BASH_BIN '$H' status --json | jq -e '.[]|select(.name==\"api2\")|.flags|index(\"OVER_COST\")'"

echo "verification gate"
commit_in "$WT" src/api/a.txt
echo edit >>"$WT/src/api/a.txt"
refuse "READY refused with modified tracked file" env CHIRP_SESSION_ID="$API" "$BASH_BIN" "$H" report READY done
(cd "$WT" && git checkout -q src/api/a.txt)
echo junk >"$WT/src/api/artefact.pyc"
check "READY allowed with untracked artefact (warns)" bash -c "CHIRP_SESSION_ID='$API' $BASH_BIN '$H' report READY done 2>&1 | grep -q 'NOT part of your commit'"
rm "$WT/src/api/artefact.pyc"
check "READY with clean tree" env CHIRP_SESSION_ID="$API" "$BASH_BIN" "$H" report READY done
refuse "accept before verify refused" h accept api
commit_in "$WT" FAIL
refuse "verify fails when tests fail" h verify api
refuse "accept after failing verify refused" h accept api
(cd "$WT" && git rm -q FAIL && git commit -qm unfail)
touch "$WT/FAIL"
refuse "in-place verify sees untracked file" h verify api
check "--clean-checkout verifies the commit only" h verify api --clean-checkout
check "clean checkout removed" bash -c "! git -C '$WT' worktree list | grep -q xh-verify"
rm "$WT/FAIL"
check "test-created artefacts don't break consistency" h config --test-cmd 'test ! -e FAIL && touch build.out'
check "verify passes" h verify api
check "verification consistent despite artefact" st -e '.tasks[0].verifications|last|.consistent and .clean'
h config --test-cmd 'test ! -e FAIL' >/dev/null; rm -f "$WT/build.out"
refuse "accept refused: verification used an old test command" h accept api
check "re-verify with current command" h verify api
check "verification records sha+exit" st -e --arg h "$(git -C "$WT" rev-parse HEAD)" '.tasks[0].verifications|last|.sha==$h and .exitCode==0'
check "accept" h accept api --note lgtm
check "acceptance bound to sha" st -e --arg h "$(git -C "$WT" rev-parse HEAD)" '.tasks[0].acceptance.sha==$h'

echo "stale acceptance"
commit_in "$WT" src/api/b.txt
check "status flags STALE_ACCEPTANCE" bash -c "$BASH_BIN '$H' status --json | jq -e '.[0].flags|index(\"STALE_ACCEPTANCE\")'"
refuse "integrate refuses stale acceptance" h integrate
check "worker report on new sha invalidates acceptance" env CHIRP_SESSION_ID="$API" "$BASH_BIN" "$H" report READY again
check "acceptance cleared + history kept" st -e '.tasks[0].acceptance==null and (.tasks[0].invalidated|length)==1'

echo "scope"
commit_in "$WT" README "changed"
check "verify ok" h verify api
refuse "accept refuses out-of-scope change" h accept api
check "accept with explicit override" h accept api --allow-out-of-scope "readme typo agreed"

echo "finish safety"
WT2="$(wt_of "$API2")"
commit_in "$WT2" src/api/v2/c.txt
refuse "finish refuses unintegrated work" h finish --cleanup
check "nothing deleted after refusal" test -d "$WT2"

echo "integrate + deploy-check"
refuse "deploy-check fails before integration" h deploy-check
check "integrate merges accepted sha + runs tests" h integrate
check "task marked integrated" st -e '.tasks[0].status=="integrated" and .tasks[0].integration.sha==.tasks[0].acceptance.sha'
refuse "deploy-check still fails (api2 open)" h deploy-check
check "verify api2" h verify api2
check "accept api2" h accept api2
touch "$MOCK_REPO/artefact.untracked"
check "integrate api2 (untracked artefact in lead checkout ok)" h integrate
check "deploy-check passes" h deploy-check

echo "cleanup"
echo dirt >"$WT2/untracked.txt"
check "finish --cleanup with dirty worktree completes but keeps it" h finish --cleanup --delete-branches
check "dirty worktree kept" test -d "$WT2"
check "clean merged worktree deleted" test ! -d "$WT"
check "merged branch deleted" bash -c "! git -C '$MOCK_REPO' rev-parse --verify -q refs/heads/hier/api"
echo edit >>"$WT2/src/api/v2/c.txt"
check "finish --discard-untracked still keeps tracked changes" h finish --cleanup --discard-untracked
check "worktree with tracked changes kept" test -d "$WT2"
(cd "$WT2" && git checkout -q src/api/v2/c.txt)
check "finish --discard-untracked removes untracked-only worktree" h finish --cleanup --discard-untracked --delete-branches
check "untracked-only worktree deleted" test ! -d "$WT2"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
