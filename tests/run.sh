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
st() { jq "$@" "$XIRP_HIERARCHY_STATE/$LEAD_ID/tasks.json"; }
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

echo "spawn + registration (bug 1)"
check "spawn without --after" h spawn --name api --goal "do api" --owns src/api
check "task without --after is recorded" st -e '.tasks|length==1 and .[0].after==null and .[0].name=="api"'
refuse "overlapping ownership refused" h spawn --name api2 --goal g --owns src/api/v2
check "overlap allowed when sequenced --after owner" h spawn --name api2 --goal g --owns src/api/v2 --after api
check "--after recorded" st -e '.tasks[1].after == .tasks[0].id'
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

echo "verification gate"
commit_in "$WT" src/api/a.txt
echo dirt >"$WT/src/api/dirty.txt"
refuse "READY refused with uncommitted changes" env CHIRP_SESSION_ID="$API" "$BASH_BIN" "$H" report READY done
rm "$WT/src/api/dirty.txt"
check "READY with clean tree" env CHIRP_SESSION_ID="$API" "$BASH_BIN" "$H" report READY done
refuse "accept before verify refused" h accept api
commit_in "$WT" FAIL
refuse "verify fails when tests fail" h verify api
refuse "accept after failing verify refused" h accept api
(cd "$WT" && git rm -q FAIL && git commit -qm unfail)
check "verify passes" h verify api
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
check "integrate api2" h integrate
check "deploy-check passes" h deploy-check

echo "cleanup"
echo dirt >"$WT2/untracked.txt"
check "finish --cleanup with dirty worktree completes but keeps it" h finish --cleanup --delete-branches
check "dirty worktree kept" test -d "$WT2"
check "clean merged worktree deleted" test ! -d "$WT"
check "merged branch deleted" bash -c "! git -C '$MOCK_REPO' rev-parse --verify -q refs/heads/hier/api"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
