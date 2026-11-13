#!/usr/bin/env bash
# Tests for the factory's scripts: factory/bin/job, route and gate.
#
# Usage: factory/tests/run.sh [test-name...]      (no names: run all)
#
# Each test gets a throwaway git repo with this factory copied in, a local
# tracker (.scratch/ tickets), a trivial checks.sh and a fake Orca CLI that
# logs every call and answers like `worker-start --json`. Agents are played by
# the test: it writes intake.md, spec.md, build.md and the reviews itself. No
# network, no real agents, nothing outside the temp dir.
set -uo pipefail

FACTORY_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${FACTORY_TEST_TMP:-$(mktemp -d)}"
mkdir -p "$TMP_ROOT"
PASS=0
FAIL=0
FAILED=()

# ---- helpers ---------------------------------------------------------------

new_repo() {  # new_repo <name>: cd into a fresh repo with the factory installed
  local dir="$TMP_ROOT/$1"
  rm -rf "$dir" && mkdir -p "$dir/bin" "$dir/repo"
  cat > "$dir/bin/orca" <<'EOF'
#!/usr/bin/env bash
log="$(dirname "$0")/calls.log"; n=$(( $(wc -l < "$log" 2>/dev/null || echo 0) + 1 ))
[[ " $* " == *" --spec-file - "* ]] && cat >> "$(dirname "$0")/specs.log"
echo "$*" >> "$log"
echo "{\"ok\":true,\"result\":{\"dispatchId\":\"ctx_fake$n\",\"state\":\"ready\"}}"
EOF
  chmod +x "$dir/bin/orca"
  export ORCA_CLI_COMMAND="$dir/bin/orca" CALLS="$dir/bin/calls.log" SPECS="$dir/bin/specs.log"
  cd "$dir/repo" || exit 1
  git init -q -b master && git config user.email t@t && git config user.name t
  mkdir -p factory && cp -r "$FACTORY_SRC/bin" "$FACTORY_SRC/agents" "$FACTORY_SRC/config.json" factory/
  rm -rf factory/bin/__pycache__
  printf '#!/usr/bin/env bash\nset -e\ntest ! -f FAIL\n' > factory/checks.sh
  python3 - <<'EOF'
import json
p = "factory/config.json"; c = json.load(open(p))
c.update(base_branch="master", concurrency=3, notify="", tracker="local", merge_method="merge",
         worktree_cache_dirs=["target/factory-jobs/{name}", "target/factory-jobs/{name}-native"])
json.dump(c, open(p, "w"), indent=2)
EOF
  mkdir -p .scratch/f/issues
  printf '/factory/jobs/\n/.worktrees/\n/target/\n' > .gitignore
  echo base > x.txt
}

ticket() {  # ticket <nn> <title> [extra lines...]
  local nn="$1" title="$2"; shift 2
  { printf '# %s: %s\n\n' "$nn" "$title"; for l in "$@"; do printf '%s\n\n' "$l"; done
    printf '**Status:** ready-for-agent\n\nDo it.\n'; } > ".scratch/f/issues/$nn-t.md"
}

commit_all() { git add -A && git commit -qm "${1:-setup}"; }

J() { factory/bin/job "$@"; }

intake() {  # intake <job> <risk> <surfaces> [extra header lines]
  printf 'DECISION: ACCEPT\nRISK: %s\nSURFACES: %s\nRESCOPED: no\nSIZE: small\nSPLIT: no\n%s\n## Summary\n- ok\n\n## Scope\nx\n\n## Follow-ups\nNone.\n' \
    "$2" "$3" "${4:-}" > "factory/jobs/$1/intake.md"
}

ready() {  # ready <job>: a READY build.md with a self-review
  printf 'STATUS: READY\n\n# Build\n\n## Summary\n- ok\n\n## Self-review\nChecked.\n' > "factory/jobs/$1/build.md"
}

review() {  # review <job> <round> <lens> <PASS|CHANGES>
  printf 'VERDICT: %s\n\n## Summary\n- ok\n\n## Standards\nNone.\n\n## Spec\nMet.\n\n## Findings\nNone.\n' "$4" \
    > "factory/jobs/$1/round-$2/review-$3.md"
}

to_build() {  # to_build <ticket> <risk> <surfaces>: create .. build round 1; prints the job id
  local id; id=$(J create "f/$1") || return 1
  intake "$id" "$2" "$3"
  factory/bin/route "$id" >/dev/null && J advance "$id" spec >/dev/null
  echo "# Spec" > "factory/jobs/$id/spec.md"
  J advance "$id" build >/dev/null
  echo "$id"
}

build_commit() {  # build_commit <job> <file> <content>
  (cd ".worktrees/$1" && echo "$3" > "$2" && git add "$2" && git commit -qm "build $2")
}

to_review() {  # to_review <job>: READY → gate → review
  ready "$1" && J advance "$1" gate >/dev/null && factory/bin/gate "$1" >/dev/null && J advance "$1" review >/dev/null
}

field() { python3 -c "import json,sys; d=json.load(open('factory/jobs/$1/job.json')); print(eval(sys.argv[1], {}, {'d': d}))" "$2"; }

status_of() { grep -m1 -o 'Status:\*\* [a-z-]*' ".scratch/f/issues/$1-t.md" | cut -d' ' -f2; }

check() {  # check <description> <actual> <expected substring>
  if [[ "$2" == *"$3"* ]]; then return 0; fi
  echo "    FAIL: $1"; echo "      expected: $3"; echo "      got:      $(echo "$2" | head -5)"
  return 1
}

# ---- tests -----------------------------------------------------------------

t_local_happy_path() {
  new_repo happy; ticket 01 One; commit_all
  local id; id=$(to_build 01 low none) || return 1
  build_commit "$id" y.txt y; to_review "$id"
  review "$id" 1 code PASS
  J advance "$id" approve >/dev/null; printf 'APPROVE\n\n## Why\nok\n' > "factory/jobs/$id/decision.md"
  mkdir -p "target/factory-jobs/$id/debug" "target/factory-jobs/$id-native" target/factory/debug
  local out; out=$(J merge "$id")
  check "merge reports" "$out" "merged factory/$id into master" &&
  check "job's target dirs freed" "[$(ls -A target/factory-jobs)]" "[]" &&
  check "shared target kept" "$(ls target/factory)" "debug" &&
  check "ticket done" "$(status_of 01)" "done" &&
  check "master has the work" "$(git show master:y.txt)" "y" &&
  check "history" "$(field "$id" "[h['stage'] for h in d['history']]")" "'review', 'approve', 'merging', 'merged'" &&
  check "clean job, no retro" "$out" "no retro: the job went through without friction"
}

t_review_needs_standards_and_spec() {
  new_repo sections; ticket 01 One; commit_all
  local id; id=$(to_build 01 low none); build_commit "$id" y.txt y; to_review "$id"
  printf 'VERDICT: PASS\n\n## Summary\n- ok\n\n## Findings\nNone.\n' > "factory/jobs/$id/round-1/review-code.md"
  local out; out=$(J advance "$id" approve 2>&1)
  check "refused" "$out" "review-code.md doesn't count" && check "names the section" "$out" "## Standards"
}

t_ready_needs_self_review() {
  new_repo selfreview; ticket 01 One; commit_all
  local id; id=$(to_build 01 low none); build_commit "$id" y.txt y
  printf 'STATUS: READY\n\n# Build\n' > "factory/jobs/$id/build.md"
  check "refused" "$(J advance "$id" gate 2>&1)" "no \`## Self-review\`"
}

t_job_start_routes_agents() {
  new_repo routing; ticket 01 One; commit_all
  local id; id=$(to_build 01 medium "ui, security"); J start "$id" builder >/dev/null
  build_commit "$id" y.txt y; to_review "$id"
  for r in code ux ui security; do J start "$id" "reviewer-$r" >/dev/null; done
  check "builder on codex" "$(grep 'r1' "$CALLS" | grep 'builder' )" "--agent codex" &&
  check "code review on claude" "$(grep 'reviewer-code r1' "$CALLS")" "--agent claude --model opus" &&
  check "dispatch recorded" "$(field "$id" "d['dispatch']['reviewer-code']")" "ctx_fake"
}

t_ui_changes_switch_builder() {
  new_repo fallback; ticket 01 One; commit_all
  local id; id=$(to_build 01 medium "ui, security"); J start "$id" builder >/dev/null
  build_commit "$id" y.txt y; to_review "$id"
  for r in code ui security; do review "$id" 1 "$r" PASS; done; review "$id" 1 ux CHANGES
  local out; out=$(J advance "$id" build)
  check "switch announced" "$out" "builder is now claude/opus" &&
  check "send refuses old builder" "$(J send "$id" builder hi 2>&1)" "has no builder worker recorded" &&
  check "code review moves to codex" "$(field "$id" "d['agents']['reviewers']['code']['agent']")" "codex" &&
  check "security moves to codex" "$(field "$id" "d['agents']['reviewers']['security']['agent']")" "codex"
}

t_base_sync_conflict() {
  new_repo basesync; ticket 01 One; commit_all
  local id; id=$(to_build 01 low none); build_commit "$id" x.txt job; to_review "$id"
  review "$id" 1 code CHANGES
  echo master > x.txt && git commit -qam "master edit"
  J advance "$id" build >/dev/null
  check "conflict recorded" "$(head -1 "factory/jobs/$id/round-2/base-sync.md")" "SYNC: CONFLICT"
}

t_merge_conflict_goes_back_to_builder() {
  new_repo mergeback; ticket 01 One; commit_all
  local id; id=$(to_build 01 low none); build_commit "$id" x.txt job; to_review "$id"
  review "$id" 1 code PASS; J advance "$id" approve >/dev/null
  printf 'APPROVE\n\n## Why\nok\n' > "factory/jobs/$id/decision.md"
  echo master > x.txt && git commit -qam "master edit"
  local out; out=$(J merge "$id")
  check "back to builder" "$out" "back to the builder for round 2" &&
  check "stage build" "$(field "$id" "d['stage']")" "build" &&
  check "merge-back file" "$(head -1 "factory/jobs/$id/round-2/merge-back.md")" "MERGE: BACK"
}

t_approve_escalated_job() {
  new_repo approve; ticket 01 One; commit_all
  local id; id=$(to_build 01 low none); build_commit "$id" y.txt y; to_review "$id"
  review "$id" 1 code PASS; J advance "$id" approve >/dev/null
  printf 'ESCALATE\n\n## Why\nhuman\n' > "factory/jobs/$id/decision.md"; J advance "$id" needs-human >/dev/null
  check "waits" "$(status_of 01)" "ready-for-human"
  local out; out=$(J approve "$id")
  check "merged" "$out" "merged factory/$id into master" && check "done" "$(status_of 01)" "done"
}

t_partial_continue_then_swap() {
  new_repo partial; ticket 01 One; commit_all
  local id; id=$(to_build 01 low none)
  printf 'STATUS: PARTIAL\n\n## Remaining\n- rest\n' > "factory/jobs/$id/build.md"
  check "first continue" "$(J continue "$id")" "continue 1/3" &&
  check "second swaps" "$(J continue "$id")" "builder is now claude/opus" &&
  check "third continue" "$(J continue "$id")" "continue 3/3" &&
  check "fourth escalates" "$(J continue "$id")" "needs-human"
}

t_slices() {
  new_repo slices; mkdir -p a b; touch a/.k b/.k; ticket 01 Big; commit_all
  local id; id=$(J create f/01)
  intake "$id" low none; sed -i 's/SPLIT: no/SPLIT: yes/; s/SIZE: small/SIZE: large/' "factory/jobs/$id/intake.md"
  factory/bin/route "$id" >/dev/null; J advance "$id" spec >/dev/null
  printf '# Big\n\n## Slices\n### Slice 1: A\n**Owns:** a/\n**Needs:** none\n**Criteria:** 1\n\n### Slice 2: B\n**Owns:** b/\n**Needs:** 1\n**Criteria:** 2\n' > "factory/jobs/$id/spec.md"
  J advance "$id" build >/dev/null
  check "slice 2 waits" "$(J slice-start "$id" 2 2>&1)" "waits for slices [1]"
  J slice-start "$id" 1 >/dev/null
  (cd ".worktrees/$id-s1" && echo 1 > a/1 && echo z > x.txt && git add -A && git commit -qm s1)
  printf 'STATUS: READY\n\n## Self-review\nok\n' > "factory/jobs/$id/slice-1.md"
  check "outside owns refused" "$(J slice-done "$id" 1 2>&1)" "changed files it doesn't own"
  (cd ".worktrees/$id-s1" && git checkout -q HEAD~1 -- x.txt && git commit -qam fix)
  mkdir -p "target/factory-jobs/$id-s1" "target/factory-jobs/$id"
  check "slice 1 merged" "$(J slice-done "$id" 1)" "slice 1 done"
  [[ "$(ls target/factory-jobs)" == "$id" ]] || { echo "    FAIL: slice target dir not freed, or job dir gone: $(ls target/factory-jobs)"; return 1; }
  J slice-start "$id" 2 >/dev/null
  (cd ".worktrees/$id-s2" && test -f a/1 && echo 2 > b/2 && git add -A && git commit -qm s2)
  printf 'STATUS: READY\n\n## Self-review\nok\n' > "factory/jobs/$id/slice-2.md"
  check "all merged" "$(J slice-done "$id" 2)" "all 2 slices merged" &&
  check "gate passes" "$(J advance "$id" gate && factory/bin/gate "$id")" "GATE: PASS"
}

t_blocked_slice_resumes_after_feedback() {
  new_repo slice-resume; mkdir -p a b c; touch a/.k b/.k c/.k; ticket 01 Big; commit_all
  local id; id=$(J create f/01)
  intake "$id" low none; sed -i 's/SPLIT: no/SPLIT: yes/; s/SIZE: small/SIZE: large/' "factory/jobs/$id/intake.md"
  factory/bin/route "$id" >/dev/null; J advance "$id" spec >/dev/null
  printf '# Big\n\n## Slices\n### Slice 1: A\n**Owns:** a/\n**Needs:** none\n\n### Slice 2: B\n**Owns:** b/\n**Needs:** 1 (parsers)\n\n### Slice 3: C\n**Owns:** c/\n**Needs:** 2 (mapping, see 7), 1 (parsers)\n' > "factory/jobs/$id/spec.md"
  J advance "$id" build >/dev/null
  check "needs keep every number" "$(field "$id" "[s['needs'] for s in d['slices']]")" "[[], [1], [2, 1]]" || return 1
  J slice-start "$id" 1 >/dev/null
  (cd ".worktrees/$id-s1" && echo 1 > a/1 && git add -A && git commit -qm s1)
  printf 'STATUS: READY\n\n## Self-review\nok\n' > "factory/jobs/$id/slice-1.md"; J slice-done "$id" 1 >/dev/null
  J slice-start "$id" 2 >/dev/null
  (cd ".worktrees/$id-s2" && echo half > b/2 && git add -A && git commit -qm "s2 half")
  printf 'STATUS: BLOCKED\n\n## Blocked\nWhich format?\n' > "factory/jobs/$id/slice-2.md"
  check "parks the job" "$(J slice-done "$id" 2)" "needs-human: slices 2, 3 are blocked" || return 1
  local out; out=$(echo 'Use JSON.' | J feedback "$id")
  check "feedback lists the slices" "$out" "slice-start $id 2 (resumes on its branch)" &&
  check "states" "$(field "$id" "[s['state'] for s in d['slices']]")" "['done', 'resume', 'pending']" &&
  check "slice 3 still waits" "$(J slice-start "$id" 3 2>&1)" "waits for slices [2, 1]" &&
  check "resume starts" "$(J slice-start "$id" 2)" "slice 2 resumes in" &&
  check "work kept" "$(cat ".worktrees/$id-s2/b/2")" "half" &&
  J start "$id" builder-s2 >/dev/null &&
  check "builder told to resume" "$(tail -3 "$SPECS")" "read slice-2.md (the last report) and feedback-1.md" || return 1
  (cd ".worktrees/$id-s2" && echo json > b/2 && git commit -qam "s2 done")
  printf 'STATUS: READY\n\n## Self-review\nok\n' > "factory/jobs/$id/slice-2.md"
  check "slice 3 next" "$(J slice-done "$id" 2)" "slice-start $id 3" &&
  J slice-start "$id" 3 >/dev/null && J start "$id" builder-s3 >/dev/null &&
  check "slice 3 gets the feedback" "$(tail -3 "$SPECS")" "read feedback-1.md" || return 1
  (cd ".worktrees/$id-s3" && echo 3 > c/3 && git add -A && git commit -qm s3)
  printf 'STATUS: READY\n\n## Self-review\nok\n' > "factory/jobs/$id/slice-3.md"
  check "all merged" "$(J slice-done "$id" 3)" "all 3 slices merged"
}

t_follow_ups_filed_once() {
  new_repo followups; ticket 01 One; commit_all
  local id; id=$(J create f/01); intake "$id" low none
  python3 - "factory/jobs/$id/intake.md" <<'EOF'
import sys; p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace("## Follow-ups\nNone.", "## Follow-ups\n- Do the other half: it was too big."))
EOF
  factory/bin/route "$id" >/dev/null; J advance "$id" spec >/dev/null
  check "ticket created" "$(cat .scratch/f/issues/02-*.md)" "**Status:** needs-triage" &&
  check "capitalised" "$(cat .scratch/f/issues/02-*.md)" "It was too big" &&
  check "recorded" "$(field "$id" "d['follow_ups'][0]['issue']")" "f/02"
}

t_hold_resume_rewind_route() {
  new_repo steer; ticket 01 Risky; commit_all
  local id; id=$(J create f/01); intake "$id" high none
  factory/bin/route "$id" >/dev/null; J advance "$id" spec >/dev/null; echo "# Spec v1" > "factory/jobs/$id/spec.md"
  check "paused after spec" "$(J advance "$id" build)" "paused"
  check "waits as human" "$(status_of 01)" "ready-for-human"
  sleep 1.2; echo "# Spec v2 by human" > "factory/jobs/$id/spec.md"
  check "resume with edit" "$(J resume "$id")" "with your edited spec.md" &&
  check "binding note" "$(tail -1 "factory/jobs/$id/spec.md")" "This version is binding" &&
  check "route-set" "$(J route-set "$id" builder=claude/opus code=claude/sonnet)" "code now run on the builder's agent" &&
  check "rewind" "$(echo 'other approach' | J rewind "$id" spec)" "back to spec with feedback-1.md" &&
  check "old spec kept" "$(ls "factory/jobs/$id")" "spec-1.md"
}

t_hold_from_ticket_and_budget() {
  new_repo holdticket; ticket 01 Held '**Factory:** hold after intake'; ticket 02 Costly; commit_all
  local id; id=$(J create f/01); intake "$id" low none; factory/bin/route "$id" >/dev/null
  check "paused after intake" "$(J advance "$id" spec)" "paused"
  python3 - <<'EOF'
import json; p = "factory/config.json"; c = json.load(open(p)); c["max_cost_usd"] = -1; json.dump(c, open(p, "w"))
EOF
  local id2; id2=$(J create f/02); intake "$id2" low none; factory/bin/route "$id2" >/dev/null
  check "over budget pauses" "$(J advance "$id2" spec)" "paused" &&
  check "budget reason" "$(field "$id2" "d['paused']['after']")" "budget"
}

t_blocked_by() {
  new_repo blocked; ticket 01 First; ticket 02 Second '**Blocked by:** 01 (needs PB-009 work)'; commit_all
  check "02 waits on 01" "$(J queue)" "blocked by f/01"
}

t_queue_selection() {
  new_repo selection
  for n in 10 11 12 13 14; do ticket $n "T$n"; done
  sed -i 's/ready-for-agent/needs-triage/' .scratch/f/issues/13-t.md
  mkdir -p .scratch/g/issues && printf '# 11: Other\n\n**Status:** ready-for-agent\n' > .scratch/g/issues/11-o.md
  commit_all
  local out; out=$(J queue f/11-14)
  check "range picks 11, 12, 14" "$(echo "$out" | awk '$1=="new"{print $2}' | xargs)" "f/11 f/12 f/14" &&
  check "not-queued ticket said so" "$out" "not labeled ready-for-agent (Status: needs-triage)" &&
  check "10 left out" "[$(echo "$out" | grep -c 'f/10')]" "[0]" &&
  check "bare number is ambiguous" "$(J queue 11 2>&1)" "write <feature>/11" &&
  check "bare unique number" "$(J queue 12 | cut -f2)" "f/12" &&
  check "whole feature" "$(J queue g | cut -f1,2 | xargs)" "new g/11" &&
  check "list and concurrency" "$(J queue f/10, f/11,f/12 f/14 | cut -f1 | xargs)" "new new new hold" &&
  check "bad selection" "$(J queue f/x 2>&1)" "isn't an issue" &&
  J queue f/12 >/dev/null &&
  check "bare queue keeps the selection" "$(J queue | awk '$1=="new"{print $2}' | xargs)" "f/12" &&
  check "says it is limited" "$(J queue)" "limited to this run's selection: f/12" &&
  check "create refuses outside it" "$(J create f/14 2>&1)" "outside this run's selection" &&
  check "--all shows every issue" "$(J queue --all | awk '$1=="new"{print $2}' | xargs)" "f/10 f/11 f/12" &&
  check "--all keeps it" "$(J create f/14 2>&1)" "outside this run's selection" &&
  J queue --clear >/dev/null &&
  check "--clear drops it" "[$(J queue | grep -c limited)]" "[0]"
}

t_feature_branch_finish() {
  new_repo feature; mkdir -p .scratch/feat/issues
  printf '# Feat\n\n**Branch:** feature/x\n' > .scratch/feat/spec.md
  printf '# 01: C\n\n**Status:** ready-for-agent\n\nc\n' > .scratch/feat/issues/01-c.md; commit_all
  local id; id=$(J create feat/01)
  check "targets feature/x" "$(field "$id" "d['base']")" "feature/x"
  intake "$id" low none; factory/bin/route "$id" >/dev/null; J advance "$id" spec >/dev/null
  echo s > "factory/jobs/$id/spec.md"; J advance "$id" build >/dev/null
  build_commit "$id" c.txt c; to_review "$id"; review "$id" 1 code PASS; J advance "$id" approve >/dev/null
  printf 'APPROVE\n\n## Why\nok\n' > "factory/jobs/$id/decision.md"
  check "finish refuses early" "$(J finish feature/x 2>&1)" "still has open work"
  check "merge hints finish" "$(J merge "$id")" "every ticket for feature/x is done"
  echo m > m.txt && git add m.txt && git commit -qm "master moves"
  check "asks for review" "$(J finish feature/x)" "start the feature review"
  check "review starts" "$(J feature-review feature/x)" "feature review started"
  printf 'VERDICT: PASS\n\n## Findings\nNone.\n' > factory/jobs/_features/feature-x-review.md
  check "merged" "$(J finish feature/x)" "feature/x: merged into master" &&
  check "master has it" "$(git show master:c.txt)" "c"
}

t_feature_finish_conflict() {
  new_repo featureconflict; commit_all
  git branch feature/y master; git checkout -q feature/y && echo y > x.txt && git commit -qam y && git checkout -q master
  echo z > x.txt && git commit -qam z
  check "conflict left to human" "$(J finish feature/y 2>&1)" "conflict, needs a human" &&
  check "master untouched" "$(cat x.txt)" "z"
}

t_builder_kept_open_then_released() {
  new_repo keepopen; ticket 01 One; commit_all
  local id; id=$(to_build 01 low none); J start "$id" builder >/dev/null
  check "builder kept open" "$(grep "$id builder r1" "$CALLS")" "--keep-open" &&
  check "send carries the brief" "$(J send "$id" builder 'round 2' >/dev/null; tail -1 "$CALLS")" "agents/builder.md"
  build_commit "$id" y.txt y; to_review "$id"; review "$id" 1 code PASS
  J advance "$id" approve >/dev/null; printf 'APPROVE\n\n## Why\nok\n' > "factory/jobs/$id/decision.md"; J merge "$id" >/dev/null
  check "released on merge" "$(grep worker-release "$CALLS")" "--dispatch ctx_fake"
}

t_worktree_root_outside_repo() {
  new_repo wtroot; ticket 01 One; commit_all
  local root="$TMP_ROOT/wtroot/outside"
  python3 - "$root" <<'PY'
import json, sys; p = "factory/config.json"; c = json.load(open(p)); c["worktree_root"] = sys.argv[1]; json.dump(c, open(p, "w"))
PY
  local id; id=$(to_build 01 low none)
  check "worktree outside" "$(field "$id" "d['worktree']")" "$root/repo/$id" &&
  check "exists there" "$(git -C "$root/repo/$id" branch --show-current)" "factory/$id" &&
  check "nothing in .worktrees" "$(ls .worktrees 2>&1)" "No such file"
}

t_small_low_skips_spec_and_cheap_models() {
  new_repo skipspec; ticket 01 Tiny; ticket 02 Medium; commit_all
  local id; id=$(J create f/01); intake "$id" low none
  printf '\n## Acceptance criteria\n1. tiny works: `true`\n' >> "factory/jobs/$id/intake.md"
  factory/bin/route "$id" >/dev/null
  local out; out=$(J advance "$id" spec)
  check "spec skipped" "$out" "spec skipped" &&
  check "in build" "$(field "$id" "d['stage']")" "build" &&
  check "spec from intake" "$(cat "factory/jobs/$id/spec.md")" "tiny works" &&
  check "approver on sonnet at low risk" "$(J worker "$id" approver)" "--model sonnet"
  local id2; id2=$(J create f/02); intake "$id2" medium security; factory/bin/route "$id2" >/dev/null
  check "medium keeps the spec" "$(J advance "$id2" spec)" "spec (round 0)" &&
  check "spec on opus at medium" "$(J worker "$id2" spec)" "--model opus" &&
  check "security on sonnet below high" "$(field "$id2" "d['agents']['reviewers']['security']['model']")" "sonnet"
}

t_high_risk_security_on_opus() {
  new_repo riskup; ticket 01 Risky; commit_all
  local id; id=$(J create f/01); intake "$id" high security; factory/bin/route "$id" >/dev/null
  check "security upgraded" "$(field "$id" "d['agents']['reviewers']['security']['model']")" "opus"
}

t_merge_starts_retro_and_commits_ticket() {
  new_repo retro; ticket 01 One; commit_all
  local id; id=$(to_build 01 low none); build_commit "$id" y.txt y; to_review "$id"; review "$id" 1 code CHANGES
  J advance "$id" build >/dev/null; build_commit "$id" z.txt z; to_review "$id"; review "$id" 2 code PASS
  J advance "$id" approve >/dev/null; printf 'APPROVE\n\n## Why\nok\n' > "factory/jobs/$id/decision.md"
  local out; out=$(J merge "$id")
  check "retro started on friction" "$(grep "$id retro" "$CALLS")" "--agent claude --model sonnet" &&
  check "retro dispatch" "$(field "$id" "d['dispatch'].get('retro')")" "ctx_fake" &&
  check "ticket committed" "$(git log --oneline -1)" "Close f/01" &&
  check "ticket clean" "[$(git status --short .scratch)]" "[]"
}

t_untouched_lenses_carry_pass() {
  new_repo skiplens; ticket 01 One; commit_all
  python3 - <<'EOF'
import json; p = "factory/config.json"; c = json.load(open(p)); c["max_rounds"] = 5
lens = {"paths": ["apps/native/*", "apps/shared/*"], "except": ["apps/native/*_tests.rs"]}
c["review_skip"] = {"ux": lens, "ui": lens}; json.dump(c, open(p, "w"))
EOF
  local id; id=$(to_build 01 medium "ui, security"); mkdir -p ".worktrees/$id/apps/native"
  build_commit "$id" apps/native/a.rs a; to_review "$id"
  check "round 1 skips nothing" "$(field "$id" "d['skipped_reviews']")" "{}"
  review "$id" 1 code PASS; review "$id" 1 security PASS; review "$id" 1 ui PASS; review "$id" 1 ux CHANGES
  J advance "$id" build >/dev/null
  mkdir -p ".worktrees/$id/crates"; build_commit "$id" crates/core.rs c
  ready "$id"; J advance "$id" gate >/dev/null; factory/bin/gate "$id" >/dev/null
  local out; out=$(J advance "$id" review)
  check "round 2 starts the rest" "$out" "start reviewers: code, ux, security" &&
  check "ui skipped" "$out" "skipped reviewer-ui: PASS in round 1" &&
  check "carried file passes" "$(head -1 "factory/jobs/$id/round-2/review-ui.md")" "VERDICT: PASS" &&
  check "start refuses skipped" "$(J start "$id" reviewer-ui 2>&1)" "reviewer-ui is skipped in round 2" &&
  check "ux CHANGES not carried" "[$(ls "factory/jobs/$id/round-2")]" "checks.md" &&
  check "no ux file" "$(test -f "factory/jobs/$id/round-2/review-ux.md" && echo yes || echo no)" "no"
  review "$id" 2 code CHANGES; review "$id" 2 security PASS; review "$id" 2 ux PASS
  J advance "$id" build >/dev/null
  mkdir -p ".worktrees/$id/apps/native/src"; build_commit "$id" apps/native/src/x_tests.rs t
  ready "$id"; J advance "$id" gate >/dev/null; factory/bin/gate "$id" >/dev/null
  out=$(J advance "$id" review)
  check "tests file ignored, code and security run" "$out" "start reviewers: code, security" &&
  check "ux carried" "$out" "skipped reviewer-ux" && check "ui carried again" "$out" "skipped reviewer-ui"
  review "$id" 3 code CHANGES; review "$id" 3 security PASS
  J advance "$id" build >/dev/null; build_commit "$id" apps/native/a.rs b
  ready "$id"; J advance "$id" gate >/dev/null; factory/bin/gate "$id" >/dev/null
  out=$(J advance "$id" review)
  check "native change runs everyone" "$out" "start reviewers: code, ux, ui, security" &&
  check "nothing skipped" "[$(echo "$out" | grep -c skipped)]" "[0]"
}

# ---- runner ----------------------------------------------------------------

all_tests=$(declare -F | awk '{print $3}' | grep '^t_')
selected=("$@")
[[ ${#selected[@]} -eq 0 ]] && read -ra selected <<< "$(echo $all_tests)"
for t in "${selected[@]}"; do
  [[ "$t" == t_* ]] || t="t_$t"
  # A test fails when it returns non-zero or when any check in it printed FAIL.
  if (set +e; "$t") > "$TMP_ROOT/$t.out" 2>&1 && ! grep -q '^    FAIL:' "$TMP_ROOT/$t.out"; then
    PASS=$((PASS + 1)); echo "ok   ${t#t_}"
  else
    FAIL=$((FAIL + 1)); FAILED+=("${t#t_}"); echo "FAIL ${t#t_}"; sed 's/^/     /' "$TMP_ROOT/$t.out" | tail -15
  fi
done
echo
echo "$PASS passed, $FAIL failed (temp files in $TMP_ROOT)"
[[ $FAIL -eq 0 ]]
