#!/usr/bin/env bash
# Tests for the factory's scripts: factory/bin/job, route and gate.
#
# Usage: factory/tests/run.sh [test-name...]      (no names: run all)
#
# Each test gets a throwaway git repo with this factory copied in, a local
# tracker (.scratch/ tickets), a trivial checks.sh and a fake Orca CLI that
# logs every call and answers like `worker-start --json`. Agents are played by
# the test: it writes intake.md, spec.md, build.md and the reviews itself. No
# network, no real agents, nothing outside the temp dir. The t_gh_* tests run the
# GitHub tracker against a local bare `origin` and a fake `gh` (see new_gh_repo).
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
if [[ "$1 $2" == "orchestration worker-show" ]]; then  # FAKE_WORKER=running|settled (default)
  echo "{\"ok\":true,\"result\":{\"stage\":\"${FAKE_WORKER:-settled}\"}}"; exit 0
fi
if [[ "$1 $2" == "orchestration send" ]]; then  # FAKE_SEND_NEW=1: the worker was gone, Orca starts a follow-up
  to="${*#*--to dispatch:}"; to="${to%% *}"
  if [[ -n "${FAKE_SEND_NEW:-}" ]]; then
    echo "{\"ok\":true,\"result\":{\"delivery\":\"started_fresh\",\"followUpOf\":\"$to\",\"dispatchId\":\"ctx_fake$n\",\"state\":\"ready\"}}"
  else
    echo "{\"ok\":true,\"result\":{\"messageId\":\"msg_$n\"}}"
  fi
  exit 0
fi
echo "{\"ok\":true,\"result\":{\"dispatchId\":\"ctx_fake$n\",\"state\":\"ready\"}}"
EOF
  chmod +x "$dir/bin/orca"
  export ORCA_CLI_COMMAND="$dir/bin/orca" CALLS="$dir/bin/calls.log" SPECS="$dir/bin/specs.log"
  # No orchestrator session unless a test plays one (as A, B ... with a live CLAUDE_PID).
  unset CLAUDE_CODE_SESSION_ID CLAUDECODE CLAUDE_PID ORCA_TERMINAL_HANDLE FAKE_WORKER
  cd "$dir/repo" || exit 1
  git init -q -b master && git config user.email t@t && git config user.name t
  mkdir -p factory && cp -r "$FACTORY_SRC/bin" "$FACTORY_SRC/agents" "$FACTORY_SRC/config.json" factory/
  rm -rf factory/bin/__pycache__
  printf '#!/usr/bin/env bash\nset -e\ntest ! -f FAIL\n' > factory/checks.sh
  python3 - <<'EOF'
import json
p = "factory/config.json"; c = json.load(open(p))
c.setdefault("hold", {})["only_when_needed"] = False  # most tests want every high-risk spec held
c.update(base_branch="master", concurrency=3, notify="", tracker="local", merge_method="merge", worktree_root=None, worktree_setup="", replace_builder_after_partials=2,
         min_risk_for_surface={"security": "medium"},
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

set_config() {  # set_config <key> <json value> [<key> <json value>...]: edit factory/config.json
  python3 - "$@" <<'EOF'
import json, sys; p = "factory/config.json"; c = json.load(open(p)); a = sys.argv[1:]
c.update({a[i]: json.loads(a[i + 1]) for i in range(0, len(a), 2)}); json.dump(c, open(p, "w"), indent=2)
EOF
}

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

# ---- GitHub mode -----------------------------------------------------------
#
# new_gh_repo: the same repo, but tracker github, a bare repo as `origin` and a
# fake `gh` on PATH. The fake keeps its state as JSON next to itself: issue-<n>.json
# (what `gh issue view` prints), pr.json (one PR: `pr create` writes it, `pr view`
# prints it with headRefOid read from origin unless pr.json pins one, `pr merge`
# records mergedHead) and merge-fail.json ({"count": n, "stderr": s, "run": cmd}:
# the next n `pr merge` calls run cmd, then fail with s).
# Every call is logged to $GH_LOG; checks.sh logs each gate mode to $GATES_LOG.

new_gh_repo() {  # new_gh_repo <name>: like new_repo, then GitHub mode; commits and pushes master
  new_repo "$1"
  local dir="$TMP_ROOT/$1"
  cat > "$dir/bin/gh" <<'EOF'
#!/usr/bin/env python3
import json, subprocess, sys
from pathlib import Path
d = Path(__file__).resolve().parent
args = sys.argv[1:]
with open(d / "gh.log", "a") as f:
    f.write(" ".join(args) + "\n")
load = lambda n: json.loads((d / n).read_text()) if (d / n).exists() else None
save = lambda n, v: (d / n).write_text(json.dumps(v))
opt = lambda k: args[args.index(k) + 1] if k in args else None
cmd, pr = args[:2], load("pr.json")
head = lambda: subprocess.run(["git", "-C", str(d.parent / "origin.git"), "rev-parse", "refs/heads/" + pr["headRefName"]],
                              capture_output=True, text=True).stdout.strip()
if cmd == ["api", "user"]:
    print("op")
elif cmd == ["issue", "view"]:
    print(json.dumps(load(f"issue-{args[2]}.json")))
elif cmd == ["issue", "list"]:  # open issues with the label, from issue-<n>.json
    want = opt("--label")
    found = [load(f.name) for f in sorted(d.glob("issue-*.json"))]
    print(json.dumps([{"number": i["number"], "title": i["title"]} for i in found
                      if i["state"] == "OPEN" and want in [l["name"] for l in i["labels"]]]))
elif cmd[0] == "api" and cmd[1].endswith("/dependencies/blocked_by"):  # issue-<n>.json "blocked_by": [numbers]
    n = cmd[1].split("/issues/")[1].split("/")[0]
    if (d / "deps-fail").exists():
        sys.exit("HTTP 502")
    print(json.dumps([{"number": b, "state": load(f"issue-{b}.json")["state"].lower()}
                      for b in (load(f"issue-{n}.json") or {}).get("blocked_by", [])]))
elif cmd in (["issue", "comment"], ["issue", "edit"], ["pr", "comment"], ["pr", "close"]):
    pass
elif cmd == ["issue", "close"]:
    i = load(f"issue-{args[2]}.json"); i["state"] = "CLOSED"; save(f"issue-{args[2]}.json", i)
elif cmd == ["pr", "create"]:
    save("pr.json", {"number": 7, "url": "https://github.com/o/r/pull/7", "headRefName": opt("--head"),
                     "state": "OPEN", "isDraft": "--draft" in args, "statusCheckRollup": []})
    print("https://github.com/o/r/pull/7")
elif cmd == ["pr", "list"]:
    ok = pr and pr["state"] == "OPEN" and opt("--head") in (None, pr["headRefName"])
    print(json.dumps([pr] if ok else []))
elif cmd == ["pr", "view"]:
    print(json.dumps({"headRefOid": head(), **pr}))
elif cmd == ["pr", "ready"]:
    pr["isDraft"] = False; save("pr.json", pr)
elif cmd == ["pr", "merge"]:
    fail = load("merge-fail.json")
    if fail and fail["count"] > 0:
        fail["count"] -= 1; save("merge-fail.json", fail)
        subprocess.run(fail.get("run") or "true", shell=True)  # e.g. another PR lands meanwhile
        sys.exit(fail["stderr"])
    pr["state"], pr["mergedHead"] = "MERGED", head(); save("pr.json", pr)
else:
    sys.exit(f"fake gh: unsupported call: gh {' '.join(args)}")
EOF
  # land <file> <content> [<file> <content>...]: another PR lands on origin's master; prints its sha.
  # A merge-fail hook can run it.
  cat > "$dir/bin/land" <<'EOF'
#!/usr/bin/env bash
set -e; tmp="$(dirname "$0")/land-$$"; git clone -q "$(dirname "$0")/../origin.git" "$tmp/c"; cd "$tmp/c"
git config user.email t@t; git config user.name t
while (( $# )); do mkdir -p "$(dirname "$1")"; echo "$2" > "$1"; git add "$1"; shift 2; done
git commit -qm "other PR"; git push -q origin master; git rev-parse HEAD
EOF
  chmod +x "$dir/bin/gh" "$dir/bin/land"
  export PATH="$dir/bin:$PATH" GH="$dir/bin" GH_LOG="$dir/bin/gh.log" GATES_LOG="$dir/bin/gates.log"
  export FACTORY_CI_POLL_SECONDS=0.05  # job merge polls CI fast; no check within the grace = no CI
  sed -i 's/"tracker": "local"/"tracker": "github"/' factory/config.json
  set_config ci_start_grace_seconds 0 ci_wait_minutes 0.01
  printf '#!/usr/bin/env bash\nset -e\necho "$FACTORY_GATE" >> "$GATES_LOG"\ntest ! -f FAIL\n' > factory/checks.sh
  git init -q --bare "$dir/origin.git" && git remote add origin "$dir/origin.git"
  commit_all && git push -q -u origin master
}

gh_issue() {  # gh_issue <n> <title> [body]: an open ready-for-agent issue
  python3 - "$GH/issue-$1.json" "$1" "$2" "${3:-Do it.}" <<'EOF'
import json, sys
p, n, title, body = sys.argv[1:]
json.dump({"number": int(n), "title": title, "body": body, "author": {"login": "op"},
           "labels": [{"name": "ready-for-agent"}], "state": "OPEN",
           "url": f"https://github.com/o/r/issues/{n}", "comments": []}, open(p, "w"))
EOF
}

gh_pr_set() {  # gh_pr_set <python statement on pr>: edit the fake's pr.json
  python3 -c "import json; p='$GH/pr.json'; pr=json.load(open(p)); $1; json.dump(pr, open(p, 'w'))"
}

gh_to_approve() {  # gh_to_approve <issue> [<file> <content>...]: create .. review on GitHub, PR pushed
  local id; id=$(J create "$1") || return 1; shift  # the build commits y.txt, or the files given
  intake "$id" low none; factory/bin/route "$id" >/dev/null && J advance "$id" spec >/dev/null || return 1
  echo "# Spec" > "factory/jobs/$id/spec.md"; J advance "$id" build >/dev/null
  (( $# )) || set -- y.txt y
  while (( $# )); do mkdir -p ".worktrees/$id/$(dirname "$1")"; build_commit "$id" "$1" "$2"; shift 2; done
  (cd ".worktrees/$id" && git push -q -u origin "factory/$id" 2>/dev/null &&
   gh pr create --draft --base master --head "factory/$id" --title t --body b >/dev/null)
  to_review "$id"; review "$id" 1 code PASS
  echo "$id"
}

gh_to_merging() {  # gh_to_merging <issue> [<file> <content>...]: .. approve with an APPROVE decision
  local id; id=$(gh_to_approve "$@") || return 1
  J advance "$id" approve >/dev/null; printf 'APPROVE\n\n## Why\nok\n' > "factory/jobs/$id/decision.md"
  echo "$id"
}

merge_fails() {  # merge_fails <n> <stderr> [cmd]: the next n `gh pr merge` calls run cmd, then fail
  python3 -c "import json, sys; json.dump({'count': int(sys.argv[1]), 'stderr': sys.argv[2], 'run': sys.argv[3]}, open('$GH/merge-fail.json', 'w'))" "$1" "$2" "${3:-}"
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

builder_cfg() {  # builder_cfg <key> <json value>: edit config.json builder.<key>
  python3 - "$@" <<'EOF2'
import json, sys; p = "factory/config.json"; c = json.load(open(p))
c["builder"][sys.argv[1]] = json.loads(sys.argv[2]); json.dump(c, open(p, "w"), indent=2)
EOF2
}

ui_round() {  # ui_round <job> <round>: a build, the gate, every review PASS but ux CHANGES, back to build
  build_commit "$1" "y$2.txt" y; to_review "$1"
  review "$1" "$2" code PASS; review "$1" "$2" ux CHANGES; review "$1" "$2" ui PASS
  J advance "$1" build
}

t_codex_fixes_ui_first() {
  new_repo uifixes; ticket 01 One; commit_all; set_config max_rounds 5; builder_cfg ui_fixes_before_fallback 2
  local id; id=$(to_build 01 low ui)
  check "round 1 CHANGES: codex keeps it" "$(ui_round "$id" 1; field "$id" "d['agents']['builder']['agent']")" "codex" &&
  check "round 2 CHANGES: codex keeps it" "$(ui_round "$id" 2; field "$id" "d['agents']['builder']['agent']")" "codex" &&
  check "round 3 CHANGES: claude takes over" "$(ui_round "$id" 3)" "builder is now claude/opus"
}

t_last_round_goes_to_fallback() {
  new_repo uilast; ticket 01 One; commit_all; set_config max_rounds 3; builder_cfg ui_fixes_before_fallback 5
  local id; id=$(to_build 01 low ui)
  check "round 1: codex keeps it" "$(ui_round "$id" 1; field "$id" "d['agents']['builder']['agent']")" "codex" &&
  check "round 3 is the last: claude gets it" "$(ui_round "$id" 2)" "is the last one"
}

t_ui_changes_switch_builder() {
  new_repo fallback; ticket 01 One; commit_all; builder_cfg ui_fixes_before_fallback 0
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

t_security_surface_raises_low_risk() {
  new_repo riskfloor; ticket 01 Auth; commit_all
  local id; id=$(J create f/01); intake "$id" low security
  printf '\n## Acceptance criteria\n1. rejects: `true`\n' >> "factory/jobs/$id/intake.md"
  factory/bin/route "$id" >/dev/null
  local out; out=$(J advance "$id" spec)
  check "risk raised" "$out" "risk raised low → medium" &&
  check "spec not skipped" "$(field "$id" "d['stage']")" "spec" &&
  check "medium risk" "$(field "$id" "d['intake']['risk']")" "medium"
}

t_sync_commits_leftover_work() {
  new_repo dirtysync; ticket 01 One; commit_all
  local id; id=$(to_build 01 low none)
  echo left > ".worktrees/$id/left.txt"  # a blocked builder's uncommitted red tests
  printf 'STATUS: BLOCKED\n\n## Summary\n- no\n\n## Blocked\nx\n' > "factory/jobs/$id/build.md"
  J advance "$id" needs-human >/dev/null
  echo m > m.txt && git add m.txt && git commit -qm "master moves"
  echo "go on" | J feedback "$id" >/dev/null
  local bs; bs=$(cat "factory/jobs/$id/round-2/base-sync.md")
  check "synced" "$bs" "SYNC: MERGED" &&
  check "says it committed" "$bs" "left.txt" &&
  check "work kept" "$(git -C ".worktrees/$id" log --format=%s -3)" "keep uncommitted work"
}

t_blocked_builder_proposal() {
  new_repo blocked; ticket 01 One; commit_all
  local id; id=$(to_build 01 low none)
  printf 'STATUS: BLOCKED\n\n## Summary\n- no\n\n## Blocked\nTests cannot pass.\n\n## Proposed change\nScope becomes tests plus the fix in a.ts.\n' \
    > "factory/jobs/$id/build.md"
  J advance "$id" needs-human >/dev/null
  local dec; dec=$(cat "factory/jobs/$id/decision.md")
  check "proposal shown" "$dec" "Scope becomes tests plus the fix in a.ts." &&
  check "one-line approval" "$dec" "factory/bin/job feedback $id"
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
  check "round 2 runs code and the lens that asked" "$out" "start reviewers: code, ux" &&
  check "ui skipped" "$out" "skipped reviewer-ui: PASS in round 1" &&
  check "security carried at medium" "$out" "skipped reviewer-security: PASS in round 1" &&
  check "carried file passes" "$(head -1 "factory/jobs/$id/round-2/review-ui.md")" "VERDICT: PASS" &&
  check "start refuses skipped" "$(J start "$id" reviewer-ui 2>&1)" "reviewer-ui is skipped in round 2" &&
  check "no ux file" "$(test -f "factory/jobs/$id/round-2/review-ux.md" && echo yes || echo no)" "no" || return 1
  J start "$id" reviewer-ux >/dev/null
  check "ux told to review the fixes" "$(tail -3 "$SPECS")" "Follow-up review: your lens last reviewed" || return 1
  review "$id" 2 code CHANGES; review "$id" 2 ux PASS
  J advance "$id" build >/dev/null
  mkdir -p ".worktrees/$id/apps/native/src"; build_commit "$id" apps/native/src/x_tests.rs t
  ready "$id"; J advance "$id" gate >/dev/null; factory/bin/gate "$id" >/dev/null
  out=$(J advance "$id" review)
  check "tests file ignored, only code runs" "$out" "start reviewers: code"$'\n' &&
  check "ux carried" "$out" "skipped reviewer-ux" && check "ui carried again" "$out" "skipped reviewer-ui"
  review "$id" 3 code CHANGES
  J advance "$id" build >/dev/null; build_commit "$id" apps/native/a.rs b
  ready "$id"; J advance "$id" gate >/dev/null; factory/bin/gate "$id" >/dev/null
  out=$(J advance "$id" review)
  check "native change runs ux and ui again" "$out" "start reviewers: code, ux, ui"$'\n' &&
  check "security still carried" "$out" "skipped reviewer-security"
}

t_high_risk_reruns_security() {
  new_repo highrerun; ticket 01 One; commit_all
  local id; id=$(to_build 01 high "security"); J resume "$id" >/dev/null
  build_commit "$id" a.txt a; to_review "$id"
  for l in $(field "$id" "' '.join(d['reviews'])"); do review "$id" 1 "$l" PASS; done
  review "$id" 1 code CHANGES
  J advance "$id" build >/dev/null; build_commit "$id" a.txt b
  ready "$id"; J advance "$id" gate >/dev/null; factory/bin/gate "$id" >/dev/null
  local out; out=$(J advance "$id" review)
  check "code and security run at high" "$out" "start reviewers: code, security"
}

t_reject_running_job() {
  new_repo rejectrun; ticket 01 One; commit_all
  local id; id=$(to_build 01 low none); build_commit "$id" a.txt a; to_review "$id"
  check "reject needs a reason" "$(J reject "$id" </dev/null 2>&1)" "no reason on stdin" &&
  check "rejected from review" "$(echo 'not needed' | J reject "$id")" "rejected" &&
  check "stage" "$(field "$id" "d['stage']")" "rejected" &&
  check "worktree gone" "$(test -d ".worktrees/$id" && echo yes || echo no)" "no"
}

t_new_dependencies_pause() {
  new_repo deps; ticket 01 One; commit_all
  local id; id=$(J create f/01); intake "$id" medium none
  factory/bin/route "$id" >/dev/null; J advance "$id" spec >/dev/null
  printf '# S\n\n## Requirements\n1. x\n\n## New dependencies\n- left-pad: pads\n\n## Assumptions\nNone.\n' \
    > "factory/jobs/$id/spec.md"
  check "pauses for dependencies" "$(J advance "$id" build)" "paused" &&
  check "paused after dependencies" "$(field "$id" "d['paused']['after']")" "dependencies" &&
  J resume "$id" >/dev/null &&
  check "approval recorded" "$(field "$id" "d['dependencies_approved']['names']")" "left-pad: pads" &&
  check "resumed at build" "$(field "$id" "d['stage']")" "build"
}

t_no_dependencies_no_pause() {
  new_repo nodeps; ticket 01 One; commit_all
  local id; id=$(J create f/01); intake "$id" medium none
  factory/bin/route "$id" >/dev/null; J advance "$id" spec >/dev/null
  printf '# S\n\n## New dependencies\nNone.\n' > "factory/jobs/$id/spec.md"
  check "builds right away" "$(J advance "$id" build)" "build (round 1)"
}

t_codex_model_and_effort() {
  new_repo codexmodel; ticket 01 One; ticket 02 Two; commit_all
  local id; id=$(to_build 01 low none)
  check "low builds on terra low" "$(field "$id" "d['agents']['builder']")" "'effort': 'low'" &&
  J start "$id" builder >/dev/null &&
  check "model and effort reach Orca" "$(tail -1 "$CALLS")" "--agent codex --model gpt-6.1-terra --effort low" &&
  check "preset" "$(J route-set "$id" builder=sol-high)" "codex/gpt-6.1-sol:high" &&
  check "explicit effort" "$(J route-set "$id" builder=codex/gpt-6.1-terra:medium)" "codex/gpt-6.1-terra:medium" &&
  check "bad entry" "$(J route-set "$id" builder=gpt 2>&1)" "terra-low"
}

t_gh_happy_path() {
  new_gh_repo ghhappy; gh_issue 1 One
  local id; id=$(gh_to_merging 1) || return 1
  local out; out=$(J merge "$id" 2>&1)
  check "merged" "$out" "merged PR #7" &&
  check "stage" "$(field "$id" "d['stage']")" "merged" &&
  check "branch deleted on origin" "[$(git -C "$GH/../origin.git" branch --list "factory/$id")]" "[]" &&
  check "one merge gate" "$(grep -c merge "$GATES_LOG")" "1"
}

t_gh_feature_finish_pr_only() {
  new_gh_repo ghfinishpr
  git branch feature/p master; git checkout -q feature/p && echo p > p.txt && git add p.txt && git commit -qm p && git checkout -q master
  git push -q origin feature/p
  set_config feature_review false
  local out; out=$(J finish feature/p --pr 2>&1)
  check "pr left open" "$out" "is open; merge it on GitHub" &&
  check "not merged" "$(grep -c 'pr merge' "$GH_LOG")" "0" &&
  check "report" "$(head -1 factory/jobs/_features/feature-p.md)" "FINISH: PR OPEN"
}

gh_issue_set() {  # gh_issue_set <n> <python statement on i>: edit the fake's issue-<n>.json
  python3 -c "import json; p='$GH/issue-$1.json'; i=json.load(open(p)); $2; json.dump(i, open(p, 'w'))"
}

t_gh_blocked_by_waits() {
  new_gh_repo ghblocked
  gh_issue 1 First; gh_issue 2 Second; gh_issue 3 Third $'Do it.\n\n## Blocked by\n\n- [First](https://github.com/o/r/issues/1)\n'
  gh_issue 4 Fourth $'## Blocked by\n\nNone (can start immediately).\n'
  gh_issue_set 2 'i["blocked_by"] = [1]'
  local q; q=$(J queue)
  check "native dependency waits" "$q" $'wait\t2\t-\t-\tblocked by #1' &&
  check "body section waits" "$q" $'wait\t3\t-\t-\tblocked by #1' &&
  check "None doesn't block" "$q" $'new\t4' &&
  check "create refuses" "$(J create 2 2>&1)" "blocked by #1" || return 1
  gh_issue_set 1 'i["state"] = "CLOSED"'
  q=$(J queue)
  check "free once closed" "$q" $'new\t2' && check "body one too" "$q" $'new\t3' || return 1
  touch "$GH/deps-fail"
  check "unreadable never counts as free" "$(J queue)" "couldn't read what #2 is blocked by"
}

t_gh_missing_feature_base() {
  new_gh_repo ghnobase; gh_issue 1 One '**Branch:** dev'
  printf '# Agents\n\nRelease: delete `dev`, then recreate it from master.\n' > AGENTS.md; commit_all
  local id; id=$(J create 1) || return 1
  check "dev created on origin" "$(git -C "$GH/../origin.git" branch --list dev)" "dev" || return 1
  git -C "$GH/../origin.git" update-ref -d refs/heads/dev
  intake "$id" low none; factory/bin/route "$id" >/dev/null
  local out; out=$(J advance "$id" spec 2>&1)
  check "names the branch" "$out" "origin/dev doesn't exist on GitHub any more" &&
  check "recreate from base" "$out" "git push origin origin/master:refs/heads/dev" &&
  check "AGENTS.md hint" "$out" "AGENTS.md mentions it" &&
  check "no stack trace" "[$(echo "$out" | grep -c Traceback)]" "[0]" &&
  check "still intake" "$(field "$id" "d['stage']")" "intake" &&
  check "nothing posted" "[$(grep -c 'issue comment' "$GH_LOG")]" "[0]"
}

t_gh_missing_base_branch() {
  new_gh_repo ghnomaster; gh_issue 1 One
  local id; id=$(J create 1) || return 1
  git -C "$GH/../origin.git" update-ref -d refs/heads/master
  intake "$id" low none; factory/bin/route "$id" >/dev/null
  local out; out=$(J advance "$id" spec 2>&1)
  check "names the branch" "$out" "origin/master doesn't exist on GitHub any more" &&
  check "recreate from a commit, not from itself" "$out" "git push origin <commit>:refs/heads/master" &&
  check "no AGENTS.md hint" "[$(echo "$out" | grep -c AGENTS.md)]" "[0]" &&
  check "no stack trace" "[$(echo "$out" | grep -c Traceback)]" "[0]"
}

t_gh_merge_retries_when_base_moved() {
  new_gh_repo ghretry; gh_issue 1 One
  local id; id=$(gh_to_merging 1) || return 1
  # Another PR lands while ours merges: the retry has to merge it in.
  merge_fails 1 "GraphQL: Base branch was modified. Review and try the merge again. (mergePullRequest)" \
    "$GH/land o.txt o > $GH/landed"
  local out; out=$(J merge "$id" 2>&1)
  check "retry announced" "$out" "master moved during the merge; syncing and trying again (2/3)" &&
  check "merged head has the other PR" "$(git -C "$GH/../origin.git" merge-base --is-ancestor \
    "$(cat "$GH/landed")" "$(python3 -c "import json; print(json.load(open('$GH/pr.json'))['mergedHead'])")" && echo yes)" "yes" &&
  check "merged" "$out" "merged PR #7" &&
  check "stage" "$(field "$id" "d['stage']")" "merged" &&
  check "merge gate twice" "$(grep -c merge "$GATES_LOG")" "2" &&
  check "two merge calls" "$(grep -c '^pr merge' "$GH_LOG")" "2"
}

t_gh_merge_retry_conflict_goes_back() {
  new_gh_repo ghretryconflict; gh_issue 1 One
  local id; id=$(gh_to_merging 1) || return 1
  merge_fails 1 "GraphQL: Base branch was modified. Review and try the merge again. (mergePullRequest)" \
    "$GH/land y.txt other >/dev/null"
  local out; out=$(J merge "$id" 2>&1)
  check "back to builder" "$out" "back to the builder for round 2" &&
  check "stage build" "$(field "$id" "d['stage']")" "build" &&
  check "merge-back names the conflict" "$(cat "factory/jobs/$id/round-2/merge-back.md")" "conflicts with master" &&
  check "one merge call" "$(grep -c '^pr merge' "$GH_LOG")" "1"
}

t_gh_merge_gives_up_after_three() {
  new_gh_repo ghretry3; gh_issue 1 One
  local id; id=$(gh_to_merging 1) || return 1
  merge_fails 3 "X Pull request o/r#7 is not up to date with the base branch"
  local out; out=$(J merge "$id" 2>&1)
  check "needs-human" "$out" "needs-human: The merge failed" &&
  check "stage" "$(field "$id" "d['stage']")" "needs-human" &&
  check "three merge calls" "$(grep -c '^pr merge' "$GH_LOG")" "3" &&
  check "merge gate three times" "$(grep -c merge "$GATES_LOG")" "3" &&
  check "decision says why" "$(cat "factory/jobs/$id/decision.md")" "not up to date with the base"
}

t_gh_merge_other_error_needs_human() {
  new_gh_repo ghmergeerr; gh_issue 1 One
  local id; id=$(gh_to_merging 1) || return 1
  merge_fails 1 "GraphQL: Required status check \"ci\" is failing (mergePullRequest)"
  local out; out=$(J merge "$id" 2>&1)
  check "needs-human" "$out" "needs-human: The merge failed" &&
  check "no retry" "[$(echo "$out" | grep -c 'trying again')]" "[0]" &&
  check "one merge call" "$(grep -c '^pr merge' "$GH_LOG")" "1" &&
  check "stage" "$(field "$id" "d['stage']")" "needs-human"
}

t_gh_ci_at_approve() {
  local case rollup want
  for case in fail pass pending stale; do
    new_gh_repo "ghci-$case"; gh_issue 1 One
    local id; id=$(gh_to_approve 1) || return 1
    rollup="[{'__typename': 'CheckRun', 'name': 'build', 'status': 'COMPLETED', 'conclusion': 'SUCCESS'}"
    case $case in
      fail) rollup+=", {'__typename': 'StatusContext', 'context': 'ci/test', 'state': 'FAILURE'}]"; want="CI: FAIL" ;;
      pending) rollup+=", {'__typename': 'CheckRun', 'name': 'lint', 'status': 'IN_PROGRESS', 'conclusion': ''}]"; want="CI: PENDING" ;;
      *) rollup+="]"; want="CI: PASS" ;;
    esac
    gh_pr_set "pr['statusCheckRollup'] = $rollup"
    [[ $case == stale ]] && gh_pr_set "pr['headRefOid'] = 'f00ba44' * 5"
    J advance "$id" approve >/dev/null || return 1
    local ci; ci=$(cat "factory/jobs/$id/round-1/ci.md")
    check "$case: verdict" "$(head -1 <<< "$ci")" "$want" || return 1
    case $case in
      fail) check "fail: names the check" "$ci" "- ci/test: failure" ;;
      pending) check "pending: names the check" "$ci" "- lint: pending" ;;
      stale) check "stale: head note" "$ci" "The PR head f00ba44 isn't the reviewed commit" ;;
      pass) check "pass: no head note" "[$(grep -c "isn't the reviewed commit" <<< "$ci")]" "[0]" ;;
    esac || return 1
    if [[ $case == fail ]]; then
      printf 'ESCALATE\n\n## Why\nCI is red.\n' > "factory/jobs/$id/decision.md"
      J advance "$id" needs-human >/dev/null || return 1
      local body; body=$(sed -n '/^pr comment 7/,$p' "$GH_LOG")
      check "comment has the CI line" "$body" "**CI:** FAIL" &&
      check "comment lists the failing check" "$body" "- ci/test: failure" &&
      check "comment leaves out passing checks" "[$(grep -c -- '- build: success' <<< "$body")]" "[0]" &&
      check "PR marked ready" "$(grep '^pr ready' "$GH_LOG")" "pr ready 7" || return 1
    fi
  done
}

notify_to() {  # notify_to <json list of channels>: set config.json `notify`
  python3 - "$1" <<'EOF'
import json, sys; p = "factory/config.json"; c = json.load(open(p)); c["notify"] = json.loads(sys.argv[1])
json.dump(c, open(p, "w"), indent=2)
EOF
}

messages() { grep -c '^Factory: ' "$1" 2>/dev/null || echo 0; }  # messages <file>: how many arrived

t_notify_pause_and_needs_human() {
  new_repo notify; ticket 01 Risky; ticket 02 Blocked; commit_all
  local inbox="$TMP_ROOT/notify/inbox"
  notify_to "[{\"command\": \"cat >> '$inbox'\"}]"
  local id; id=$(J create f/01); intake "$id" high none
  factory/bin/route "$id" >/dev/null; J advance "$id" spec >/dev/null; echo "# Spec" > "factory/jobs/$id/spec.md"
  check "nothing before the pause" "[$(messages "$inbox")]" "[0]" &&
  check "paused" "$(J advance "$id" build)" "paused" &&
  check "one message" "[$(messages "$inbox")]" "[1]" &&
  check "says who waits" "$(cat "$inbox")" "Factory: $id (f/01) waits for you" &&
  check "says why" "$(cat "$inbox")" "paused after spec: high risk, held for your review" &&
  check "says what to do" "$(cat "$inbox")" "Do: read factory/jobs/$id/spec.md (edit it if you want), then /factory resume $id" || return 1
  local id2; id2=$(to_build 02 low none)
  printf 'STATUS: BLOCKED\n\n## Blocked\nWhich storage format: JSON or YAML?\n' > "factory/jobs/$id2/build.md"
  J advance "$id2" needs-human >/dev/null
  check "one more message" "[$(messages "$inbox")]" "[2]" &&
  check "needs-human why" "$(tail -3 "$inbox")" "needs-human: The builder is blocked: Which storage format: JSON or YAML?" &&
  check "needs-human action" "$(tail -3 "$inbox")" "Do: read factory/jobs/$id2/decision.md, then give feedback with /factory, or reject it" &&
  check "sync doesn't repeat it" "$(J sync "$id2" >/dev/null; messages "$inbox")" "2" || return 1
  echo 'Not needed after all.' | J reject "$id2" >/dev/null
  check "reject is announced" "$(tail -2 "$inbox")" "Factory: $id2 (f/02) rejected" &&
  check "with the reason" "$(tail -1 "$inbox")" "Blocked: Not needed after all."
}

t_notify_escalation_and_run_finished() {
  new_repo notifyrun; ticket 01 One; ticket 02 Vague; commit_all
  local inbox="$TMP_ROOT/notifyrun/inbox"
  notify_to "[{\"command\": \"cat >> '$inbox'\"}, {\"command\": \"cat >> '$inbox.high'\", \"min\": \"high\"}]"
  J queue >/dev/null
  local id; id=$(to_build 01 low none); build_commit "$id" y.txt y; to_review "$id"
  review "$id" 1 code PASS; J advance "$id" approve >/dev/null
  printf 'ESCALATE\n\n## Why\n- It changes the public API.\n' > "factory/jobs/$id/decision.md"
  J advance "$id" needs-human >/dev/null
  check "escalation why" "$(cat "$inbox")" "needs-human: It changes the public API." &&
  check "escalation action" "$(cat "$inbox")" "Do: read factory/jobs/$id/decision.md, then /factory approve $id, or give feedback with /factory" || return 1
  local id2; id2=$(J create f/02)
  printf 'DECISION: NEEDS-INFO\nRISK: low\nSURFACES: none\nRESCOPED: no\nSIZE: small\nSPLIT: no\n\n## Summary\n- unclear\n\n## Questions\n1. Which page should it go on?\n\n## Follow-ups\nNone.\n' \
    > "factory/jobs/$id2/intake.md"
  J advance "$id2" needs-info >/dev/null
  check "needs-info" "$(tail -2 "$inbox")" "needs-info: intake asks: Which page should it go on?" &&
  check "needs-info action" "$(tail -1 "$inbox")" "Do: answer the question in .scratch/f/issues/02-t.md under ## Comments" &&
  check "no run end while a job runs" "[$(grep -c 'run finished' "$inbox")]" "[0]" || return 1
  J queue >/dev/null
  check "run finished once" "[$(grep -c 'run finished' "$inbox")]" "[1]" &&
  check "lists who waits" "$(tail -2 "$inbox")" "2 job(s) wait for you: $id (needs-human), $id2 (needs-info)" &&
  check "not twice" "$(J queue >/dev/null; grep -c 'run finished' "$inbox")" "1" &&
  check "approve merges and says so" "$(J approve "$id" >/dev/null; tail -2 "$inbox")" "Factory: $id (f/01) merged" &&
  check "a high-only channel got the waits, not the rest" "[$(grep '^Factory: ' "$inbox.high" | cut -d' ' -f4- | xargs)]" \
    "[waits for you waits for you]"
}

t_notify_failing_channel_never_breaks_advance() {
  new_repo notifyfail; ticket 01 Risky; commit_all
  local inbox="$TMP_ROOT/notifyfail/inbox"
  printf '#!/usr/bin/env bash\necho "$1" >> %q\n' "$inbox" > "$TMP_ROOT/notifyfail/legacy"; chmod +x "$TMP_ROOT/notifyfail/legacy"
  notify_to "[{\"command\": \"exit 3\"}, {\"command\": \"echo boom >&2; kill -9 \$\$\"},
              {\"ntfy\": \"http://127.0.0.1:9/factory\"}, {\"ntfy\": \"not a url\"},
              {\"ntfy_env\": \"FACTORY_TEST_UNSET_URL\"}, {\"bogus\": 1}, \"desktop-but-missing\",
              {\"command\": \"cat >> '$inbox'\"}, \"$TMP_ROOT/notifyfail/legacy\"]"
  local id; id=$(J create f/01); intake "$id" high none
  factory/bin/route "$id" >/dev/null; J advance "$id" spec >/dev/null; echo "# Spec" > "factory/jobs/$id/spec.md"
  local out; out=$(J advance "$id" build 2>&1)
  check "advance still works" "$out" "$id: paused" &&
  check "stage saved" "$(field "$id" "d['stage']")" "paused" &&
  check "good channel still got it" "[$(messages "$inbox")]" "[2]" &&
  check "old string form gets it as an argument" "$(tail -2 "$inbox")" "Factory: $id (f/01) waits for you: paused after spec"
}

t_notify_ntfy_headers() {
  new_repo notifyntfy; ticket 01 Risky; commit_all
  local dir="$TMP_ROOT/notifyntfy" port
  python3 - "$dir" <<'EOF' &
import http.server, json, sys
d = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"])).decode()
        json.dump({"path": self.path, "headers": dict(self.headers), "body": body}, open(d + "/got.json", "w"))
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(d + "/port", "w").write(str(s.server_port))
s.timeout = 20; s.handle_request()
EOF
  for _ in $(seq 50); do [[ -s "$dir/port" ]] && break; sleep 0.1; done
  port=$(cat "$dir/port")
  export FACTORY_TEST_NTFY="http://127.0.0.1:$port/factory-test"
  notify_to '[{"ntfy_env": "FACTORY_TEST_NTFY"}]'
  local id; id=$(J create f/01); intake "$id" high none
  factory/bin/route "$id" >/dev/null; J advance "$id" spec >/dev/null; echo "# Spec" > "factory/jobs/$id/spec.md"
  J advance "$id" build >/dev/null; wait
  unset FACTORY_TEST_NTFY
  local got; got=$(python3 -c "import json; g = json.load(open('$dir/got.json')); h = g['headers']; print(g['path'], h['Title'], h['Priority'], h['Tags'], '|', g['body'])")
  check "topic from the env var" "$got" "/factory-test" &&
  check "title" "$got" "Factory: $id (f/01) waits for you" &&
  check "priority and tags" "$got" "high hourglass" &&
  check "body has the action" "$got" "Do: read factory/jobs/$id/spec.md"
}

as() {  # as <session> <command...>: run as Claude Code session <session>, alive as this test
  local s="$1"; shift
  CLAUDE_CODE_SESSION_ID="$s" CLAUDE_PID=$$ "$@"
}

t_claim_and_stand_in() {
  new_repo claim; ticket 01 One; ticket 02 Two; ticket 03 Three; commit_all
  check "only a session claims" "$(J claim 2>&1)" "CLAUDE_CODE_SESSION_ID isn't set" &&
  check "A claims" "$(as A J claim --run run_1)" "claimed: session A, Orca run run_1" || return 1
  local id; id=$(as A J create f/01) || return 1
  check "B can't create" "$(as B J create f/02 2>&1)" "this session is a stand-in" &&
  check "B can't select" "$(as B J queue f/02 2>&1)" "this session is a stand-in" &&
  check "B can't clear" "$(as B J queue --clear 2>&1)" "this session is a stand-in" &&
  check "B's queue says so" "$(as B J queue | head -1)" "note"$'\t'"-"$'\t'"-"$'\t'"-"$'\t'"this session is a stand-in" &&
  check "B can't claim" "$(as B J claim 2>&1)" "another live session orchestrates" &&
  check "B sees the holder" "$(as B J claim --status)" "held by another session: session A, Orca run run_1" &&
  check "B can't release" "$(as B J claim --release 2>&1)" "not this session's" || return 1
  intake "$id" low none; factory/bin/route "$id" >/dev/null
  check "B moves the job on" "$(as B J advance "$id" spec)" "$id: spec (round 0)" &&
  check "a person is no stand-in" "$(J queue f/01-02 | awk '$1=="new"{print $2}')" "f/02" || return 1
  # A's process exits: the claim goes stale; B still can't start work until it claims.
  sleep 0 & wait $!; local dead=$!
  CLAUDE_CODE_SESSION_ID=A CLAUDE_PID=$dead J claim >/dev/null
  check "stale claim" "$(as B J create f/02 2>&1)" "is gone: its Claude Code process $dead has exited" &&
  check "B takes a stale claim" "$(as B J claim)" "took over from session A" &&
  check "B creates now" "$(as B J create f/02)" "-two" &&
  check "A is the stand-in now" "$(as A J create f/03 2>&1)" "this session is a stand-in" &&
  check "A forces" "$(as A J claim --force)" "forced" &&
  check "A releases" "$(as A J claim --release)" "released: session A" &&
  check "no claim" "$(J claim --status)" "no claim" &&
  check "anyone creates without a claim" "$(as B J queue --clear >/dev/null; as B J create f/03)" "-three"
}

t_claim_takeover_names_the_run() {
  new_repo claimrun; commit_all
  sleep 0 & wait $!; local dead=$!
  CLAUDE_CODE_SESSION_ID=A CLAUDE_PID=$dead J claim --run run_7 >/dev/null
  check "run-use hint" "$(as B J claim)" "orchestration run-use --id run_7" &&
  check "heartbeat refreshed" "$(as B J queue >/dev/null; python3 -c "import json,time; print(time.time() - json.load(open('factory/jobs/_orchestrator.json'))['seen'] < 5)")" "True"
}

t_next_through_the_stages() {
  new_repo next; ticket 01 One; commit_all
  local id; id=$(J create f/01); local J_="factory/bin/job"
  check "intake: start" "$(J next "$id")" "$id: start: $J_ start $id intake" || return 1
  J start "$id" intake >/dev/null
  check "intake: wait" "$(FAKE_WORKER=running J next "$id")" "$id: wait: intake running (started" &&
  check "settled without a file: nudge" "$(J next "$id")" "$id: send: $J_ send $id intake 'You stopped without writing intake.md" || return 1
  intake "$id" low none
  check "intake: route" "$(J next "$id")" "run: factory/bin/route $id" || return 1
  factory/bin/route "$id" >/dev/null
  check "intake: advance" "$(J next "$id")" "advance: $J_ advance $id spec" || return 1
  J advance "$id" spec >/dev/null
  check "spec: start" "$(J next "$id")" "start: $J_ start $id spec" || return 1
  echo "# Spec" > "factory/jobs/$id/spec.md"
  check "spec: advance, from the list" "$(J next)" "$id: advance: $J_ advance $id build" || return 1
  J advance "$id" build >/dev/null
  check "build: start" "$(J next "$id")" "start: $J_ start $id builder" || return 1
  J start "$id" builder >/dev/null
  check "build: wait" "$(FAKE_WORKER=running J next "$id")" "wait: builder running" || return 1
  build_commit "$id" y.txt y; ready "$id"
  check "build: to the gate" "$(J next "$id")" "advance: $J_ advance $id gate" || return 1
  J advance "$id" gate >/dev/null
  check "gate: run it" "$(J next "$id")" "run: factory/bin/gate $id" || return 1
  factory/bin/gate "$id" >/dev/null
  check "gate: passed" "$(J next "$id")" "advance: $J_ advance $id review" || return 1
  J advance "$id" review >/dev/null
  check "review: start" "$(J next "$id")" "start: reviewer-code (" || return 1
  J start "$id" reviewer-code >/dev/null
  check "review: wait" "$(FAKE_WORKER=running J next "$id")" "wait: reviewer-code running" || return 1
  review "$id" 1 code CHANGES
  check "review: CHANGES" "$(J next "$id")" "advance: $J_ advance $id build" || return 1
  J advance "$id" build >/dev/null
  check "round 2: send the reviews" "$(J next "$id")" "send: $J_ send $id builder 'Round 1 reviews are in round-1/." || return 1
  J send "$id" builder "fix it" >/dev/null
  check "round 2: old build.md doesn't count" "$(FAKE_WORKER=running J next "$id")" "wait: builder running (messaged" || return 1
  build_commit "$id" z.txt z; ready "$id"
  J advance "$id" gate >/dev/null; factory/bin/gate "$id" >/dev/null; J advance "$id" review >/dev/null
  review "$id" 2 code PASS
  check "review: all PASS" "$(J next "$id")" "advance: $J_ advance $id approve" || return 1
  J advance "$id" approve >/dev/null
  check "approve: start" "$(J next "$id")" "start: $J_ start $id approver" || return 1
  printf 'ESCALATE\n\n## Why\nhuman\n' > "factory/jobs/$id/decision.md"
  check "approve: escalate" "$(J next "$id")" "advance: $J_ advance $id needs-human" || return 1
  J advance "$id" needs-human >/dev/null
  check "needs-human: wait" "$(J next "$id")" "wait: human: needs-human (ESCALATE)" || return 1
  J approve "$id" >/dev/null
  check "merged: done" "$(J next "$id")" "$id: done: merged" &&
  check "nothing in flight" "$(J next)" "no job in flight"
}

t_next_gate_fail_partial_paused() {
  new_repo nextmore; ticket 01 One; ticket 02 Held '**Factory:** hold after intake'; commit_all
  local id; id=$(to_build 01 low none)
  printf 'STATUS: PARTIAL\n\n## Remaining\n- rest\n' > "factory/jobs/$id/build.md"
  check "partial: continue" "$(J next "$id")" "run: factory/bin/job continue $id" || return 1
  J continue "$id" >/dev/null
  check "continue not sent yet" "$(J next "$id")" "start: factory/bin/job start $id builder 'Continue: read build.md" || return 1
  build_commit "$id" y.txt y; ready "$id"
  check "READY after the continue" "$(J next "$id")" "advance: factory/bin/job advance $id gate" || return 1
  build_commit "$id" FAIL x
  J advance "$id" gate >/dev/null; factory/bin/gate "$id" >/dev/null
  check "gate failed: build" "$(J next "$id")" "advance: factory/bin/job advance $id build" || return 1
  J advance "$id" build >/dev/null
  check "round 2: gate message" "$(J next "$id")" "The gate failed: read round-1/checks.md" || return 1
  (cd ".worktrees/$id" && git rm -q FAIL && git commit -qm unfail); ready "$id"
  J advance "$id" gate >/dev/null; factory/bin/gate "$id" >/dev/null
  build_commit "$id" y.txt again
  check "new commit: gate is stale" "$(J next "$id")" "run: factory/bin/gate $id" || return 1
  local id2; id2=$(J create f/02); intake "$id2" low none; factory/bin/route "$id2" >/dev/null; J advance "$id2" spec >/dev/null
  check "paused: wait" "$(J next "$id2")" "wait: human: paused after intake" &&
  check "list has a line per job" "$(J next | wc -l)" "2"
}

t_next_slices() {
  new_repo nextslices; mkdir -p a b; touch a/.k b/.k; ticket 01 Big; commit_all
  local id; id=$(J create f/01)
  intake "$id" low none; sed -i 's/SPLIT: no/SPLIT: yes/; s/SIZE: small/SIZE: large/' "factory/jobs/$id/intake.md"
  factory/bin/route "$id" >/dev/null; J advance "$id" spec >/dev/null
  printf '# Big\n\n## Slices\n### Slice 1: A\n**Owns:** a/\n**Needs:** none\n\n### Slice 2: B\n**Owns:** b/\n**Needs:** 1\n' > "factory/jobs/$id/spec.md"
  J advance "$id" build >/dev/null
  check "slice 1 ready" "$(J next "$id")" "run: factory/bin/job slice-start $id 1, then factory/bin/job start $id builder-s1" || return 1
  J slice-start "$id" 1 >/dev/null
  check "slice builder not started" "$(J next "$id")" "start: factory/bin/job start $id builder-s1" || return 1
  J start "$id" builder-s1 >/dev/null
  check "slice running" "$(FAKE_WORKER=running J next "$id")" "wait: builder-s1 running" || return 1
  (cd ".worktrees/$id-s1" && echo 1 > a/1 && git add -A && git commit -qm s1)
  printf 'STATUS: READY\n\n## Self-review\nok\n' > "factory/jobs/$id/slice-1.md"
  check "slice reported" "$(J next "$id")" "run: factory/bin/job slice-done $id 1"
}

t_resume_records_acceptance() {
  new_repo accepted; ticket 01 One; ticket 02 Two; commit_all
  local id; id=$(to_build 01 high "security")
  check "paused after spec" "$(field "$id" "d['stage']")" "paused" &&
  echo "spec ok, unattended deletion of expired drafts is fine" | J resume "$id" >/dev/null &&
  check "note in accepted.md" "$(cat "factory/jobs/$id/accepted.md")" "resumed after spec (held after spec, risk high): spec ok, unattended deletion" &&
  check "note in job.json" "$(field "$id" "d['accepted'][0]['note']")" "spec ok" || return 1
  local id2; id2=$(to_build 02 high "security")
  J resume "$id2" </dev/null >/dev/null &&
  check "default line without a note" "$(cat "factory/jobs/$id2/accepted.md")" "accepted spec.md as written"
}

t_gh_clean_merge_closes_issue() {
  new_gh_repo ghclose; gh_issue 1 One
  local id; id=$(gh_to_merging 1) || return 1
  J merge "$id" >/dev/null 2>&1
  check "issue closed" "$(python3 -c "import json; print(json.load(open('$GH/issue-1.json'))['state'])")" "CLOSED" &&
  check "summary posted" "$(cat "$GH_LOG")" "### Factory: merged" &&
  check "says clean" "$(cat "$GH_LOG")" "Clean run"
}

t_gh_approved_merge_closes_issue() {
  new_gh_repo ghopen; gh_issue 1 One
  local id; id=$(gh_to_approve 1) || return 1
  J advance "$id" approve >/dev/null
  printf 'ESCALATE\n\n## Summary\n- needs a look\n\n## Why\nx\n' > "factory/jobs/$id/decision.md"
  J advance "$id" needs-human >/dev/null; echo "ok, merge it" | J approve "$id" >/dev/null 2>&1
  check "merged" "$(field "$id" "d['stage']")" "merged" &&
  check "issue closed" "$(python3 -c "import json; print(json.load(open('$GH/issue-1.json'))['state'])")" "CLOSED" &&
  check "says why" "$(cat "$GH_LOG")" "it needed a human decision"
}

t_gh_hand_merge_closes_issue() {
  new_gh_repo ghhand; gh_issue 1 One
  local id; id=$(gh_to_approve 1) || return 1
  gh_pr_set 'pr["state"] = "MERGED"'
  J queue >/dev/null 2>&1
  check "merged" "$(field "$id" "d['stage']")" "merged" &&
  check "issue closed" "$(python3 -c "import json; print(json.load(open('$GH/issue-1.json'))['state'])")" "CLOSED" &&
  check "summary says by hand" "$(cat "$GH_LOG")" "Merged by a human."
}

t_gate_strips_coauthor_trailers() {
  new_repo trailers; ticket 01 One; commit_all
  local id; id=$(to_build 01 low none)
  (cd ".worktrees/$id" && echo a > a.txt && git add a.txt &&
   git commit -qm $'build a\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\nCo-authored-by: Sandcastle Bot <s@localhost>\n\n\U1F916 Generated with [Claude Code](https://claude.com/claude-code)')
  ready "$id"; J advance "$id" gate >/dev/null; factory/bin/gate "$id" >/dev/null
  check "message is clean" "[$(git -C ".worktrees/$id" log -1 --format=%B | grep -ci 'co-authored\|generated with')]" "[0]" &&
  check "subject kept" "$(git -C ".worktrees/$id" log -1 --format=%s)" "build a" &&
  check "gate notes it" "$(cat "factory/jobs/$id/round-1/checks.md")" "Removed Co-Authored-By" &&
  check "checks.md names the new head" "$(sed -n 2p "factory/jobs/$id/round-1/checks.md")" "$(git -C ".worktrees/$id" rev-parse HEAD)" &&
  check "no backup ref" "[$(git for-each-ref refs/original | wc -l)]" "[0]"
}

t_worktree_setup_runs() {
  new_repo wtsetup; ticket 01 One; ticket 02 Two; commit_all
  echo "SECRET=1" > .env
  python3 - <<'EOF'
import json; p = "factory/config.json"; c = json.load(open(p))
c["worktree_setup"] = 'install -Dm600 "$ORCA_ROOT_PATH/.env" .env\necho done > setup.txt'
json.dump(c, open(p, "w"))
EOF
  local id; id=$(to_build 01 low none)
  check "env copied from the main checkout" "$(cat ".worktrees/$id/.env")" "SECRET=1" &&
  check "script ran in the worktree" "$(cat ".worktrees/$id/setup.txt")" "done" &&
  check "log written" "$(head -1 "factory/jobs/$id/worktree-setup.log")" "worktree_setup exit 0" || return 1
  python3 - <<'EOF'
import json; p = "factory/config.json"; c = json.load(open(p)); c["worktree_setup"] = "exit 3"; json.dump(c, open(p, "w"))
EOF
  local id2; id2=$(to_build 02 low none 2>/dev/null)
  check "a failing setup doesn't stop the job" "$(field "$id2" "d['stage']")" "build" &&
  check "failure logged" "$(head -1 "factory/jobs/$id2/worktree-setup.log")" "exit 3"
}

t_high_risk_holds_only_when_needed() {
  new_repo holdneeded; ticket 01 One; ticket 02 Two; commit_all
  python3 -c "import json; p='factory/config.json'; c=json.load(open(p)); c['hold']['only_when_needed']=True; json.dump(c, open(p,'w'))"
  local id; id=$(J create f/01); intake "$id" high security
  factory/bin/route "$id" >/dev/null; J advance "$id" spec >/dev/null
  printf '# S\n\n## Needs a human\nNone.\n' > "factory/jobs/$id/spec.md"
  check "nothing for the human: builds" "$(J advance "$id" build)" "build (round 1)" || return 1
  local id2; id2=$(J create f/02); intake "$id2" high security
  factory/bin/route "$id2" >/dev/null; J advance "$id2" spec >/dev/null
  printf '# S\n\n## Needs a human\n- run the cleanup dry-run: pnpm cleanup --dry-run; done when 0 left\n' > "factory/jobs/$id2/spec.md"
  check "something for the human: pauses" "$(J advance "$id2" build)" "paused" &&
  check "comment lists it" "$(cat .scratch/f/issues/02-t.md)" "run the cleanup dry-run" &&
  check "next names it" "$(J next "$id2")" "wait"
}

t_gate_failures_readable() {
  new_repo gatefail; ticket 01 One; commit_all
  local id; id=$(to_build 01 low none)
  cat > factory/checks.sh <<'EOF'
#!/usr/bin/env bash
for i in $(seq 1 30); do echo "noise line $i"; done
printf '\033[31mFAIL\033[0m src/a.test.ts > adds\n'
echo "  expected 2, got 3"
printf '\033[1;31m✗ subtracts\033[0m\n'
printf '\033[31mFAIL\033[0m src/a.test.ts > adds\n'
for i in $(seq 1 100); do printf '\033[2mmore noise %s\033[0m\n' "$i"; done
exit 1
EOF
  factory/bin/gate "$id" >/dev/null
  local md; md="$(cat "factory/jobs/$id/round-1/checks.md")"
  check "verdict line kept" "$(head -2 "factory/jobs/$id/round-1/checks.md")" $'GATE: FAIL\nCOMMIT: ' &&
  check "no ANSI in checks.md" "[$(grep -c $'\033' "factory/jobs/$id/round-1/checks.md")]" "[0]" &&
  check "no ANSI in checks.log" "[$(grep -c $'\033' "factory/jobs/$id/round-1/checks.log")]" "[0]" &&
  check "failures section" "$md" "## Failures" &&
  check "failure listed once" "[$(grep -c '^- `FAIL src/a.test.ts > adds`' <<< "$md")]" "[1]" &&
  check "second failure listed" "$md" '- `✗ subtracts`' &&
  check "first failure with its context" "$md" $'FAIL src/a.test.ts > adds\n  expected 2, got 3' &&
  check "failures above the tail" "$(grep '^## ' <<< "$md" | cut -c4- | tr '\n' ,)" "Protected paths,Failures,checks.sh," || return 1
  printf '#!/usr/bin/env bash\nfor i in $(seq 1 50); do echo ok $i; done\n' > factory/checks.sh
  factory/bin/gate "$id" >/dev/null
  md="$(cat "factory/jobs/$id/round-1/checks.md")"
  check "PASS: no failures section" "[$(grep -c '## Failures' <<< "$md")]" "[0]" &&
  check "PASS: short tail" "$md" "Last 20 lines of checks.log"
}

t_gates_take_turns() {
  new_repo gatelock; ticket 01 One; ticket 02 Two; commit_all
  local a b; a=$(to_build 01 low none); b=$(to_build 02 low none)
  export TURNS="$TMP_ROOT/gatelock/turns.log"
  printf '#!/usr/bin/env bash\necho "start $(date +%%s.%%N)" >> "$TURNS"\nsleep 2\necho "end $(date +%%s.%%N)" >> "$TURNS"\n' > factory/checks.sh
  factory/bin/gate "$a" > "$TMP_ROOT/gatelock/a.out" 2>&1 &
  sleep 0.5
  local err; err=$(factory/bin/gate "$b" 2>&1 >/dev/null); wait
  check "the second gate says whom it waits for" "$err" "gate: waiting for $a's gate (since " &&
  check "it says so once" "[$(grep -c waiting <<< "$err")]" "[1]" &&
  check "one after the other" "$(awk '{print $1}' "$TURNS" | tr '\n' ' ')" "start end start end" &&
  check "the wait is recorded apart" "$(cat "factory/jobs/$b/round-1/checks.md")" "for another gate ($a) before checks.sh ran; not counted in its 2s" &&
  check "checks.sh's own time" "$(cat "factory/jobs/$b/round-1/checks.md")" "checks.sh passed in 2s" &&
  check "holder recorded" "$(cat factory/jobs/_gate.lock)" "\"job\": \"$b\"" || return 1
  python3 - <<'EOF'
import json; p = "factory/config.json"; c = json.load(open(p)); c["gate_parallel"] = 0; json.dump(c, open(p, "w"))
EOF
  : > "$TURNS"
  factory/bin/gate "$a" >/dev/null 2>&1 &
  sleep 0.5
  err=$(factory/bin/gate "$b" 2>&1 >/dev/null); wait
  check "gate_parallel 0: no waiting" "[$err]" "[]" &&
  check "gate_parallel 0: together" "$(awk '{print $1}' "$TURNS" | tr '\n' ' ')" "start start end end"
}

t_send_records_follow_up_dispatch() {
  new_repo followup; ticket 01 One; commit_all
  local id; id=$(to_build 01 low none); J start "$id" builder >/dev/null
  local d1; d1=$(J dispatch "$id" builder)
  J send "$id" builder "plain" >/dev/null
  check "a delivered message keeps the dispatch" "$(J dispatch "$id" builder)" "$d1" || return 1
  local out; out=$(FAKE_SEND_NEW=1 J send "$id" builder "round 2")
  local d2; d2=$(J dispatch "$id" builder)
  check "send says so" "$out" "follow-up dispatch $d2 (of $d1)" &&
  check "a new dispatch is recorded" "[$([[ "$d2" != "$d1" ]] && echo new)]" "[new]" &&
  check "chain recorded" "$(field "$id" "d['followed_by']['$d1']")" "$d2" &&
  check "still kept open" "$(field "$id" "d['kept_open']")" "$d2" &&
  check "next waits on the follow-up" "$(FAKE_WORKER=running J next "$id")" "wait: builder running (follow-up" &&
  check "next asks Orca about it" "$(grep worker-show "$CALLS" | tail -1)" "--dispatch $d2" || return 1
  # An older record of the worker still names the first dispatch: next follows the chain.
  python3 - "$id" "$d1" <<'EOF'
import json, sys; p = f"factory/jobs/{sys.argv[1]}/job.json"; j = json.load(open(p))
j["workers"]["builder"]["dispatch"] = sys.argv[2]; json.dump(j, open(p, "w"))
EOF
  check "next follows the chain" "$(FAKE_WORKER=running J next "$id")" "dispatch $d2" &&
  check "settled follow-up without build.md: nudge" "$(J next "$id")" "send: factory/bin/job send $id builder" &&
  check "the next send goes to the follow-up" "$(J send "$id" builder again >/dev/null; grep 'orchestration send' "$CALLS" | tail -1)" "--to dispatch:$d2"
}

t_read_only_commands_skip_a_merge() {
  new_repo busy; ticket 01 One; commit_all
  local id; id=$(to_build 01 low none)
  python3 - "factory/jobs/$id/.lock" <<'EOF' &
import fcntl, json, os, sys, time
f = open(sys.argv[1], "a+"); fcntl.flock(f, fcntl.LOCK_EX); f.seek(0); f.truncate()
f.write(json.dumps({"command": "merge", "pid": os.getpid(), "since": time.time()})); f.flush()
time.sleep(60)
EOF
  local holder=$!
  for _ in $(seq 50); do grep -q merge "factory/jobs/$id/.lock" 2>/dev/null && break; sleep 0.1; done
  local t0 out q s err; t0=$(date +%s)
  out=$(J next "$id"); local t1=$(date +%s)
  q=$(J queue); local t2=$(date +%s)
  s=$(J summary); local t3=$(date +%s)
  err=$(timeout 4 factory/bin/job advance "$id" gate 2>&1 >/dev/null)
  kill "$holder"; wait "$holder" 2>/dev/null
  check "next reports the merge" "$out" "$id: wait: merge in progress since " &&
  check "with the holder's pid" "$out" "(pid $holder)" &&
  check "next returns promptly" "[$(( t1 - t0 < 5 ))]" "[1]" &&
  check "queue shows a wait row" "$q" "$(printf 'wait\tf/01\t%s\tbuild\tmerge in progress since ' "$id")" &&
  check "queue returns promptly" "[$(( t2 - t1 < 5 ))]" "[1]" &&
  check "summary notes it" "$s" "$id: merge in progress since " &&
  check "summary returns promptly" "[$(( t3 - t2 < 5 ))]" "[1]" &&
  check "a mutating command says why it waits" "$err" "job: $id: merge in progress since " &&
  check "job.json untouched by the readers" "$(field "$id" "d['stage']")" "build" &&
  check "once free, next works again" "$(J next "$id")" "$id: start: factory/bin/job start $id builder"
}

lockfile_repo() {  # lockfile_repo <name> <regenerate command> [gh]: deps/*.txt and a deps.lock generated from them
  if [[ "${3:-}" == gh ]]; then new_gh_repo "$1"; else new_repo "$1"; ticket 01 One; fi
  mkdir -p deps && echo a > deps/a.txt && echo a > deps.lock
  set_config lockfile_regenerate "{\"deps.lock\": \"$2\"}"
  commit_all lockfile; [[ "${3:-}" == gh ]] && git push -q origin master
  return 0
}

REGEN='cat deps/*.txt | sort > deps.lock'

t_gh_lockfile_conflict_regenerated_at_merge() {
  lockfile_repo ghlock "$REGEN" gh; gh_issue 1 One
  local id; id=$(gh_to_merging 1 deps/b.txt b deps.lock $'a\nb') || return 1
  "$GH/land" deps/c.txt c deps.lock $'a\nc' >/dev/null
  local out; out=$(J merge "$id" 2>&1)
  local merged; merged=$(python3 -c "import json; print(json.load(open('$GH/pr.json'))['mergedHead'])")
  check "merged without a build round" "$out" "merged PR #7" &&
  check "still round 1" "$(field "$id" "d['round']")" "1" &&
  check "lockfile regenerated from both sides" "$(git -C "$GH/../origin.git" show "$merged:deps.lock" | tr '\n' ' ')" "a b c" &&
  check "recorded" "$(cat "factory/jobs/$id/round-1/merge-sync.md")" "Lockfile conflict in deps.lock resolved by the factory" &&
  check "log kept" "$(cat "factory/jobs/$id/round-1/lockfile-regenerate.log")" "exit 0" &&
  check "merge gate ran on it" "$(grep -c merge "$GATES_LOG")" "1"
}

t_gh_lockfile_and_code_conflict_goes_back() {
  lockfile_repo ghlockcode "$REGEN" gh; gh_issue 1 One
  local id; id=$(gh_to_merging 1 deps/b.txt b deps.lock $'a\nb' y.txt y) || return 1
  "$GH/land" deps/c.txt c deps.lock $'a\nc' y.txt other >/dev/null
  local out; out=$(J merge "$id" 2>&1)
  check "back to builder" "$out" "back to the builder for round 2" &&
  check "merge-back names the conflict" "$(cat "factory/jobs/$id/round-2/merge-back.md")" "conflicts with master" &&
  check "no regenerate for a mixed conflict" "$(test -f "factory/jobs/$id/round-1/lockfile-regenerate.log" && echo yes || echo no)" "no" &&
  check "round 2 sync: conflict for the builder" "$(head -1 "factory/jobs/$id/round-2/base-sync.md")" "SYNC: CONFLICT" &&
  check "worktree clean" "[$(git -C ".worktrees/$id" status --porcelain)]" "[]" &&
  check "no merge call" "[$(grep -c '^pr merge' "$GH_LOG")]" "[0]"
}

t_lockfile_conflict_regenerated_in_base_sync() {
  lockfile_repo locksync "$REGEN"
  local id; id=$(to_build 01 low none); mkdir -p ".worktrees/$id/deps"
  build_commit "$id" deps/b.txt b; build_commit "$id" deps.lock $'a\nb'; to_review "$id"
  echo c > deps/c.txt && printf 'a\nc\n' > deps.lock && git add -A && git commit -qm "master deps"
  review "$id" 1 code CHANGES; J advance "$id" build >/dev/null
  check "sync merged" "$(head -1 "factory/jobs/$id/round-2/base-sync.md")" "SYNC: MERGED" &&
  check "says what it did" "$(cat "factory/jobs/$id/round-2/base-sync.md")" "took master's version and ran" &&
  check "lockfile regenerated" "$(tr '\n' ' ' < ".worktrees/$id/deps.lock")" "a b c" &&
  check "merge committed" "[$(git -C ".worktrees/$id" status --porcelain)]" "[]"
}

merge_back_round() {  # merge_back_round <name>: a medium ui job approved in round 1, sent back by a
  lockfile_repo "$1" 'exit 3'  # failed lockfile regenerate; sets MB_ID (it cds, so not in a subshell)
  local id; id=$(to_build 01 medium ui) || return 1; mkdir -p ".worktrees/$id/deps"
  build_commit "$id" deps/b.txt b; build_commit "$id" deps.lock $'a\nb'; build_commit "$id" y.txt y; to_review "$id"
  for l in code ux ui; do review "$id" 1 "$l" PASS; done
  J advance "$id" approve >/dev/null; printf 'APPROVE\n\n## Summary\n- fine\n\n## Why\nok\n' > "factory/jobs/$id/decision.md"
  echo c > deps/c.txt && printf 'a\nc\n' > deps.lock && git add -A && git commit -qm "master deps"
  J merge "$id" > "$TMP_ROOT/$1.merge" 2>&1
  # The builder resolves it: the base's lockfile, regenerated.
  (cd ".worktrees/$id" && { git merge -q master >/dev/null 2>&1; true; } && printf 'a\nb\nc\n' > deps.lock &&
   git add deps.lock && git commit -q --no-edit)
  MB_ID=$id
}

t_merge_only_round_carries_reviews_and_approve() {
  merge_back_round mergeonly || return 1; local id=$MB_ID J_="factory/bin/job"
  check "regenerate failed: back to build" "$(cat "$TMP_ROOT/mergeonly.merge")" "back to the builder for round 2" &&
  check "merge-back says why" "$(cat "factory/jobs/$id/round-2/merge-back.md")" "couldn't regenerate them" || return 1
  ready "$id"; J advance "$id" gate >/dev/null; factory/bin/gate "$id" >/dev/null
  local out; out=$(J advance "$id" review)
  check "merge-only round" "$out" "merge-only round: the change is the same as round 1" &&
  check "every lens carried" "$(field "$id" "sorted(d['skipped_reviews'])")" "['code', 'ui', 'ux']" &&
  check "carried file" "$(cat "factory/jobs/$id/round-2/review-code.md")" "merge-only round: the change is the same as round 1" &&
  check "start refuses" "$(J start "$id" reviewer-code 2>&1)" "is skipped in round 2" &&
  check "next: approve" "$(J next "$id")" "advance: $J_ advance $id approve" || return 1
  out=$(J advance "$id" approve)
  check "approval carried" "$out" "approval carried from round 1" &&
  check "decision APPROVE" "$(head -1 "factory/jobs/$id/decision.md")" "APPROVE" &&
  check "decision note" "$(cat "factory/jobs/$id/decision.md")" "Carried from round 1: merge-only round" &&
  check "earlier summary kept" "$(cat "factory/jobs/$id/decision.md")" "- fine" &&
  check "next: merge" "$(J next "$id")" "run: $J_ merge $id" &&
  check "approver refused" "$(J start "$id" approver 2>&1)" "the approval is carried in round 2" || return 1
  out=$(J merge "$id")
  check "merged" "$out" "merged factory/$id into master" &&
  check "master has both deps" "$(git show master:deps.lock | tr '\n' ' ')" "a b c"
}

t_real_change_or_feedback_is_not_carried() {
  merge_back_round notcarried || return 1; local id=$MB_ID J_="factory/bin/job"
  build_commit "$id" y.txt changed; ready "$id"
  J advance "$id" gate >/dev/null; factory/bin/gate "$id" >/dev/null
  local out; out=$(J advance "$id" review)
  check "a code change: reviews run" "$out" "start reviewers: code" &&
  check "not merge-only" "$(field "$id" "d.get('merge_only')")" "None" || return 1
  for l in code ux ui; do [[ -f "factory/jobs/$id/round-2/review-$l.md" ]] || review "$id" 2 "$l" PASS; done
  J advance "$id" approve >/dev/null
  check "approver runs" "$(J next "$id")" "start: $J_ start $id approver" || return 1
  # A human's feedback round never carries, even when the change stays the same.
  printf 'ESCALATE\n\n## Why\nhuman\n' > "factory/jobs/$id/decision.md"; J advance "$id" needs-human >/dev/null
  echo "looks the same to me, rerun" | J feedback "$id" >/dev/null
  (cd ".worktrees/$id" && git commit -q --allow-empty -m "nothing new"); ready "$id"
  J advance "$id" gate >/dev/null; factory/bin/gate "$id" >/dev/null
  out=$(J advance "$id" review)
  check "feedback round: every lens runs" "$out" "start reviewers: code, ux, ui"
}

t_gh_merge_waits_for_ci() {
  local case rollup
  for case in pass fail none pending; do
    new_gh_repo "ghciwait-$case"; gh_issue 1 One
    local id; id=$(gh_to_merging 1) || return 1
    case $case in
      pass) rollup="[{'name': 'build', 'status': 'COMPLETED', 'conclusion': 'SUCCESS'}]" ;;
      fail) rollup="[{'name': 'build', 'status': 'COMPLETED', 'conclusion': 'SUCCESS'}, {'context': 'ci/test', 'state': 'FAILURE'}]" ;;
      none) rollup="[]"; set_config ci_start_grace_seconds 0.3 ;;
      pending) rollup="[{'name': 'lint', 'status': 'IN_PROGRESS', 'conclusion': ''}]" ;;
    esac
    gh_pr_set "pr['statusCheckRollup'] = $rollup"
    local out; out=$(J merge "$id" 2>&1)
    local ci; ci=$(cat "factory/jobs/$id/round-1/merge-ci.md" 2>/dev/null)
    check "$case: waits" "$out" "waiting for CI on PR #7" || return 1
    case $case in
      pass) check "pass: merged" "$out" "merged PR #7" && check "pass: recorded" "$ci" "CI: PASS" ;;
      none) check "none: merged" "$out" "merged PR #7" && check "none: recorded" "$ci" "CI: NONE" ;;
      fail) check "fail: back to build" "$out" "back to the builder for round 2: CI failed on PR #7" &&
            check "fail: merge-back names the check" "$(cat "factory/jobs/$id/round-2/merge-back.md")" "ci/test" &&
            check "fail: recorded" "$ci" "CI: FAIL" &&
            check "fail: not merged" "[$(grep -c '^pr merge' "$GH_LOG")]" "[0]" ;;
      pending) check "pending: needs-human" "$out" "needs-human: CI on PR #7 was still running" &&
               check "pending: decision says so" "$(cat "factory/jobs/$id/decision.md")" "pending lint" &&
               check "pending: recorded" "$ci" "CI: PENDING" &&
               check "pending: not merged" "[$(grep -c '^pr merge' "$GH_LOG")]" "[0]" ;;
    esac || return 1
  done
}

t_gh_ci_wait_frees_the_job() {
  new_gh_repo ghciwaitlock; gh_issue 1 One; set_config ci_wait_minutes 0.1
  local id; id=$(gh_to_merging 1) || return 1
  gh_pr_set "pr['statusCheckRollup'] = [{'name': 'lint', 'status': 'IN_PROGRESS', 'conclusion': ''}]"
  factory/bin/job merge "$id" > "$TMP_ROOT/ciwait.out" 2>&1 & local pid=$!  # not J: $! must be the job process
  for _ in $(seq 50); do grep -q ci_wait "factory/jobs/$id/job.json" && break; sleep 0.1; done
  check "next doesn't block, it waits" "$(timeout 3 factory/bin/job next "$id")" "wait: job merge (pid $pid) waiting for CI on PR #7" &&
  check "a second merge refuses" "$(timeout 3 factory/bin/job merge "$id" 2>&1)" "another \`job merge\` (pid $pid) has been waiting for CI" &&
  check "queue runs meanwhile" "$(timeout 3 factory/bin/job queue >/dev/null 2>&1 && echo ran)" "ran" || return 1
  wait "$pid"
  check "then needs-human" "$(cat "$TMP_ROOT/ciwait.out")" "needs-human: CI on PR #7 was still running" &&
  check "marker gone" "$(field "$id" "d.get('ci_wait')")" "None"
}

t_first_build_and_resume_sync_with_base() {
  new_repo firstsync; ticket 01 One; ticket 02 Risky; commit_all
  local id; id=$(J create f/01); intake "$id" medium none
  factory/bin/route "$id" >/dev/null; J advance "$id" spec >/dev/null; echo "# Spec" > "factory/jobs/$id/spec.md"
  echo m1 > m1.txt && git add m1.txt && git commit -qm "master moves during spec"
  J advance "$id" build >/dev/null
  check "spec → build syncs" "$(head -1 "factory/jobs/$id/round-1/base-sync.md")" "SYNC: MERGED" &&
  check "worktree has the base's work" "$(cat ".worktrees/$id/m1.txt")" "m1" || return 1
  local id2; id2=$(to_build 02 high security)
  check "paused" "$(field "$id2" "d['stage']")" "paused" &&
  check "no sync while paused" "$(test -f "factory/jobs/$id2/round-1/base-sync.md" && echo yes || echo no)" "no" || return 1
  echo m2 > m2.txt && git add m2.txt && git commit -qm "master moves during the pause"
  J resume "$id2" </dev/null >/dev/null
  check "resume syncs" "$(head -1 "factory/jobs/$id2/round-1/base-sync.md")" "SYNC: MERGED" &&
  check "resumed worktree has the base's work" "$(cat ".worktrees/$id2/m2.txt")" "m2"
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
cd /
if [[ $FAIL -eq 0 && -z "${FACTORY_TEST_TMP:-}" && -z "${FACTORY_TEST_KEEP:-}" ]]; then
  rm -rf "$TMP_ROOT"  # /tmp is often in RAM; keep it only when there's something to look at
  echo "$PASS passed, $FAIL failed"
else
  echo "$PASS passed, $FAIL failed (temp files in $TMP_ROOT)"
fi
[[ $FAIL -eq 0 ]]
