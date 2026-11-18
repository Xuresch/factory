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
c.setdefault("labels", {})["factory"] = None  # an installation's opt-in label; the label tests set it
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

ready() {  # ready <job>: a READY build.md with a self-review; answers every finding the reviews listed as fixed
  { printf 'STATUS: READY\n\n# Build\n\n## Summary\n- ok\n\n## Self-review\nChecked.\nPre-review: no findings.\n\n## Review findings\n'
    local f lens; for f in "factory/jobs/$1"/round-*/review-*.md; do
      [[ -f "$f" ]] || continue; lens=${f##*/review-}; lens=${lens%.md}
      grep -o '^F[0-9]* \[' "$f" | while read -r id _; do echo "$lens $id fixed: done"; done
    done; true; } > "factory/jobs/$1/build.md"
}

review() {  # review <job> <round> <lens> <PASS|CHANGES>: CHANGES lists one [should]; earlier findings are resolved
  local f earlier=""; for f in "factory/jobs/$1"/round-*/review-"$3".md; do
    [[ -f "$f" && "$f" != *"/round-$2/"* ]] && earlier+=$(grep -o '^F[0-9]* \[' "$f" | while read -r id _; do echo "$id resolved"; done)$'\n'
  done
  local findings="None."; [[ "$4" == CHANGES ]] && findings="F$2 [should] x.txt:1 fix it"
  printf 'VERDICT: %s\n\n## Summary\n- ok\n\n## Standards\nNone.\n\n## Spec\nMet.\n\n## Earlier findings\n%s\n## Findings\n%s\n' "$4" "$earlier" "$findings" \
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
# records mergedHead), merge-fail.json ({"count": n, "stderr": s, "run": cmd}:
# the next n `pr merge` calls run cmd, then fail with s) and pr-comments.json
# (what `gh api [--paginate] repos/{owner}/{repo}/<pulls|issues>/<n>/<comments|reviews>`
# lists, two per page; see pr_comment).
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
elif cmd == ["issue", "list"]:  # open issues with every --label given (AND), from issue-<n>.json
    want = [args[k + 1] for k, a in enumerate(args) if a == "--label"]
    found = [load(f.name) for f in sorted(d.glob("issue-*.json"))]
    print(json.dumps([{"number": i["number"], "title": i["title"]} for i in found
                      if i["state"] == "OPEN" and all(w in [l["name"] for l in i["labels"]] for w in want)]))
elif cmd == ["issue", "create"]:  # a new issue-<n>.json with every --label given
    n = max([int(f.stem.split("-")[1]) for f in d.glob("issue-*.json")], default=0) + 1
    save(f"issue-{n}.json", {"number": n, "title": opt("--title"), "body": opt("--body"), "author": {"login": "op"},
                             "labels": [{"name": args[k + 1]} for k, a in enumerate(args) if a == "--label"],
                             "state": "OPEN", "url": f"https://github.com/o/r/issues/{n}", "comments": []})
    print(f"https://github.com/o/r/issues/{n}")
elif cmd[0] == "api" and cmd[1].endswith("/dependencies/blocked_by"):  # issue-<n>.json "blocked_by": [numbers]
    n = cmd[1].split("/issues/")[1].split("/")[0]
    if (d / "deps-fail").exists():
        sys.exit("HTTP 502")
    print(json.dumps([{"number": b, "state": load(f"issue-{b}.json")["state"].lower()}
                      for b in (load(f"issue-{n}.json") or {}).get("blocked_by", [])]))
elif cmd[0] == "api" and any(a.startswith("repos/{owner}/{repo}/") for a in args):
    # PR comments from pr-comments.json {"pulls/comments": [...], "issues/comments": [...], "pulls/reviews": [...]},
    # two per page: --paginate prints the pages back to back, without it only the first one comes.
    path = next(a for a in args if a.startswith("repos/")).split("/")
    items = (load("pr-comments.json") or {}).get("/".join(path[3::2]), [])
    pages = [items[i:i + 2] for i in range(0, len(items), 2)] or [[]]
    print("".join(json.dumps(p) for p in (pages if "--paginate" in args else pages[:1])))
elif cmd == ["issue", "edit"]:  # --add-label / --remove-label (comma-separated) change issue-<n>.json
    i = load(f"issue-{args[2]}.json")
    drop = (opt("--remove-label") or "").split(",") + (opt("--add-label") or "").split(",")
    i["labels"] = [l for l in i["labels"] if l["name"] not in drop]
    i["labels"] += [{"name": x} for x in (opt("--add-label") or "").split(",") if x]
    save(f"issue-{args[2]}.json", i)
elif cmd in (["issue", "comment"], ["pr", "comment"], ["pr", "close"]):
    pass
elif cmd == ["issue", "close"]:
    i = load(f"issue-{args[2]}.json"); i["state"] = "CLOSED"; save(f"issue-{args[2]}.json", i)
elif cmd == ["pr", "create"]:
    save("pr.json", {"number": 7, "url": "https://github.com/o/r/pull/7", "headRefName": opt("--head"),
                     "state": "OPEN", "isDraft": "--draft" in args, "statusCheckRollup": [], "body": opt("--body")})
    print("https://github.com/o/r/pull/7")
elif cmd == ["pr", "list"]:
    ok = pr and pr["state"] == "OPEN" and opt("--head") in (None, pr["headRefName"])
    print(json.dumps([pr] if ok else []))
elif cmd == ["pr", "view"]:
    print(json.dumps({"headRefOid": head(), **pr}))
elif cmd == ["pr", "ready"]:
    pr["isDraft"] = False; save("pr.json", pr)
elif cmd == ["pr", "edit"]:
    pr["body"] = opt("--body"); save("pr.json", pr)
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

t_pre_review_before_ready() {
  new_repo prereview; ticket 01 One; commit_all
  local id; id=$(to_build 01 low none); J start "$id" builder >/dev/null
  check "builder told to pre-review" "$(cat "$SPECS")" "Pre-review: \`codex review --base master\`" || return 1
  J send "$id" builder 'round 1' >/dev/null
  check "resume carries it" "$(tail -3 "$CALLS")" "Pre-review: \`codex review --base master\`" || return 1
  build_commit "$id" y.txt y
  printf 'STATUS: READY\n\n# Build\n\n## Self-review\nChecked.\n' > "factory/jobs/$id/build.md"
  check "refused" "$(J advance "$id" gate 2>&1)" "no \`Pre-review:\` line" || return 1
  printf 'STATUS: READY\n\n# Build\n\n## Self-review\nChecked.\n- Pre-review: 1 finding, fixed.\n' > "factory/jobs/$id/build.md"
  check "accepted" "$(J advance "$id" gate 2>&1)" "gate" || return 1
  ticket 03 Three; commit_all; local id3; id3=$(to_build 03 low none); build_commit "$id3" z.txt z
  printf 'STATUS: READY\n\n# Build\n\n## Self-review\nChecked.\n' > "factory/jobs/$id3/build.md"
  check "a builder never told isn't held to it" "$(J advance "$id3" gate 2>&1)" "gate" || return 1
  builder_cfg pre_review null; : > "$SPECS"
  ticket 02 Two; commit_all; local id2; id2=$(to_build 02 low none); J start "$id2" builder >/dev/null
  check "off: no pre-review" "$(grep -c 'Pre-review' "$SPECS")" "0"
}

t_pre_review_list() {
  new_repo prereviewlist; ticket 01 One; commit_all
  builder_cfg pre_review '["codex review --base {base}", "fallow audit --base {base}"]'
  local id; id=$(to_build 01 low none); J start "$id" builder >/dev/null
  check "every command" "$(cat "$SPECS")" "Pre-review: \`codex review --base master\` and \`fallow audit --base master\`."
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

t_feedback_rule_change() {
  new_repo feedbackrule; mkdir -p .scratch/feat/issues
  printf '# Feat\n\n**Branch:** feature/r\n' > .scratch/feat/spec.md
  printf '# 01: C\n\n**Status:** ready-for-agent\n\nc\n' > .scratch/feat/issues/01-c.md; commit_all
  local id; id=$(J create feat/01)
  intake "$id" low none; factory/bin/route "$id" >/dev/null; J advance "$id" spec >/dev/null
  echo s > "factory/jobs/$id/spec.md"; J advance "$id" build >/dev/null
  printf 'STATUS: BLOCKED\n\n## Summary\n- no\n\n## Blocked\nx\n' > "factory/jobs/$id/build.md"
  J advance "$id" needs-human >/dev/null
  local out; out=$(printf 'Names may be 40 characters, not 20.\nThe rest as before.\n' | J feedback "$id" --rule)
  local rules=factory/jobs/_features/feature-r-rules.md
  check "feedback still goes to the builder" "$out" "$id: feedback-1.md, round 2" &&
  check "says it recorded the rule" "$out" "rule change recorded in $rules" &&
  check "section" "$(cat "$rules")" "## Rule changes" &&
  check "dated line, id, first line only" "$(cat "$rules")" "- $(date -u +%F) $id: Names may be 40 characters, not 20." &&
  check "not the rest" "[$(grep -c 'The rest' "$rules")]" "[0]" &&
  check "not in the finish report" "[$(ls factory/jobs/_features)]" "[feature-r-rules.md]" || return 1
  printf 'STATUS: BLOCKED\n\n## Summary\n- no\n\n## Blocked\nx\n' > "factory/jobs/$id/build.md"
  J advance "$id" needs-human >/dev/null
  echo 'Only admins may rename.' | J feedback "$id" --rule >/dev/null
  check "appended" "$(grep -c "^- .* $id: " "$rules")" "2" || return 1
  # The feature reviewer's prompt names the file (finish wrote the state it starts from).
  printf '{"worktree": "%s", "tip": "abc"}' "$PWD" > factory/jobs/_features/feature-r.json
  J feature-review feature/r >/dev/null
  check "reviewer told" "$(cat "$SPECS")" "Rule changes: $PWD/$rules." || return 1
  # On the base branch there is no feature review: nothing to record.
  ticket 02 Two; commit_all
  local id2; id2=$(to_build 02 low none)
  printf 'STATUS: BLOCKED\n\n## Summary\n- no\n\n## Blocked\nx\n' > "factory/jobs/$id2/build.md"
  J advance "$id2" needs-human >/dev/null
  check "base branch: nothing recorded" "$(echo 'x' | J feedback "$id2" --rule)" "targets master, not a feature branch"
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

t_gh_finish_pulls_origin_after_local_merge() {
  new_gh_repo ghfinishpull
  git branch feature/q master; git checkout -q feature/q && echo q > q.txt && git add q.txt && git commit -qm q && git checkout -q master
  git push -q origin feature/q
  "$GH/land" m.txt m >/dev/null; git pull -q origin master  # the base moves: finish merges it in
  check "first finish asks for review" "$(J finish feature/q)" "start the feature review" || return 1
  local wt=.worktrees/_finish-feature-q
  check "kept worktree holds the local base merge" "$(git -C "$wt" log -1 --format=%s)" "Merge" || return 1
  # A fix lands on origin/feature/q after that run: a fast-forward of the worktree can't take it.
  local c="$TMP_ROOT/ghfinishpull/fix"; git clone -q "$GH/../origin.git" "$c"
  (cd "$c" && git config user.email t@t && git config user.name t && git checkout -q feature/q &&
   echo fix > fix.txt && git add fix.txt && git commit -qm fix && git push -q origin feature/q)
  local fix; fix=$(git -C "$c" rev-parse HEAD)
  check "asks for review again" "$(J finish feature/q)" "start the feature review" &&
  check "worktree has the fix" "$(cat "$wt/fix.txt")" "fix" &&
  local tip; tip=$(python3 -c "import json; print(json.load(open('factory/jobs/_features/feature-q.json'))['tip'])") &&
  check "the checked tip contains it" "$(git -C "$wt" merge-base --is-ancestor "$fix" "$tip" && echo yes)" "yes" &&
  check "checked again" "$(python3 -c "import json; print(json.load(open('factory/jobs/_features/feature-q.json'))['checked'])")" "$tip"
}

t_gh_finish_origin_conflict() {
  new_gh_repo ghfinishpullc
  git branch feature/k master; git checkout -q feature/k && echo k > k.txt && git add k.txt && git commit -qm k && git checkout -q master
  git push -q origin feature/k
  check "first finish asks for review" "$(J finish feature/k)" "start the feature review" || return 1
  local wt=.worktrees/_finish-feature-k
  (cd "$wt" && echo mine > k.txt && git commit -qam mine)  # a local commit in the kept worktree
  local c="$TMP_ROOT/ghfinishpullc/fix"; git clone -q "$GH/../origin.git" "$c"
  (cd "$c" && git config user.email t@t && git config user.name t && git checkout -q feature/k &&
   echo theirs > k.txt && git commit -qam theirs && git push -q origin feature/k)
  local out; out=$(J finish feature/k 2>&1)
  check "conflict left to a human" "$out" "conflict, needs a human" &&
  check "report" "$(cat factory/jobs/_features/feature-k.md)" "conflicts with origin/feature/k" &&
  check "merge aborted" "[$(git -C "$wt" status --porcelain)]" "[]"
}

pr_comment() {  # pr_comment <pulls/comments|issues/comments|pulls/reviews> <id> <author> <body> [path line]
  python3 - "$GH/pr-comments.json" "$@" <<'EOF'
import json, os, sys
p, kind, id_, author, body, *where = sys.argv[1:]
d = json.load(open(p)) if os.path.exists(p) else {}
c = {"id": int(id_), "user": {"login": author}, "body": body, "created_at": f"2026-11-15T10:00:{int(id_) % 60:02d}Z",
     "html_url": f"https://github.com/o/r/pull/7#c{id_}"}
if where:
    c.update(path=where[0], line=int(where[1]))
if kind == "pulls/reviews":
    c.update(state="COMMENTED", submitted_at=c.pop("created_at"))
d.setdefault(kind, []).append(c); json.dump(d, open(p, "w"))
EOF
}

t_gh_feature_pr_comments() {
  new_gh_repo ghprcomments
  git branch feature/p master; git checkout -q feature/p && echo p > p.txt && git add p.txt && git commit -qm p && git checkout -q master
  git push -q origin feature/p
  local f=factory/jobs/_features
  check "asks for review" "$(J finish feature/p --pr)" "then run \`job finish feature/p --pr\` again" || return 1
  J feature-review feature/p >/dev/null
  printf 'VERDICT: PASS\n\n## Findings\nNone.\n' > $f/feature-p-review.md
  local out; out=$(J finish feature/p --pr 2>&1)
  check "pr opened" "$out" "is open; merge it on GitHub" &&
  check "says to run it again" "$out" "run \`job finish feature/p --pr\` again" &&
  check "a new PR has no comments to read" "[$(grep -c "^api --paginate" "$GH_LOG")]" "[0]" || return 1
  for n in 11 12 13; do pr_comment pulls/comments $n codex-bot "Inline $n" src/a.py $n; done
  pr_comment issues/comments 21 alice "Tokens end up in the logs."
  pr_comment pulls/reviews 31 bob "Please split this."
  pr_comment pulls/reviews 32 carol ""
  out=$(J finish feature/p --pr 2>&1)
  local listing; listing=$(cat $f/feature-p-pr-comments.md)
  check "untriaged comments stop it" "$out" "5 untriaged comment(s)" &&
  check "asks for the review again" "$out" "job feature-review feature/p" &&
  check "not reported clean" "$(head -1 $f/feature-p.md)" "FINISH: PR COMMENTS" &&
  check "paginated" "$(grep -c 'api --paginate repos/{owner}/{repo}/pulls/7/comments' "$GH_LOG")" "1" &&
  check "every page read" "$listing" "## inline-13 (untriaged)" &&
  check "file and line" "$listing" "- Where: src/a.py:12" &&
  check "author" "$listing" "- Author: alice" &&
  check "body" "$listing" "> Tokens end up in the logs." &&
  check "url" "$listing" "https://github.com/o/r/pull/7#c21" &&
  check "review body" "$listing" "## review-31 (untriaged)" &&
  check "empty review left out" "[$(grep -c review-32 <<< "$listing")]" "[0]" &&
  check "old review gone" "$(test -f $f/feature-p-review.md && echo yes || echo no)" "no" || return 1
  J feature-review feature/p >/dev/null
  check "reviewer gets the comments" "$(tail -3 "$SPECS")" "PR comments: $PWD/$f/feature-p-pr-comments.md" || return 1
  printf 'VERDICT: PASS\n\n## Summary\n- ok\n\n## PR comments\n- inline-11: done, handled in a.py\n- `inline-12`: **rejected**: style only\n- inline-13: done, same fix\n- comment-21: done, the logger masks tokens\n- review-31: rejected\n\n## Findings\nNone.\n' > $f/feature-p-review.md
  out=$(J finish feature/p --pr 2>&1)
  check "a comment without a reason is untriaged" "$out" "left PR comments untriaged: review-31" || return 1
  sed -i 's/^- review-31: rejected$/- review-31: rejected — the split is the next feature/' $f/feature-p-review.md
  out=$(J finish feature/p --pr 2>&1)
  check "all triaged: open" "$out" "its 5 comment(s) are triaged" &&
  check "reported open" "$(head -1 $f/feature-p.md)" "FINISH: PR OPEN" &&
  check "triage shown" "$(cat $f/feature-p-pr-comments.md)" "## inline-12 (triaged, rejected: style only)" || return 1
  pr_comment issues/comments 22 alice "One more thing."
  out=$(J finish feature/p --pr 2>&1)
  check "only the new one" "$out" "1 untriaged comment(s)" &&
  check "earlier triage kept" "$(cat $f/feature-p-pr-comments.md)" "## comment-21 (triaged, done: the logger masks tokens)" &&
  check "never merged" "[$(grep -c 'pr merge' "$GH_LOG")]" "[0]"
}

merge_feature_job() {  # merge_feature_job <ticket>: run a local ticket through to merged; prints the merge output
  local id; id=$(J create "$1") || return 1
  intake "$id" low none; factory/bin/route "$id" >/dev/null; J advance "$id" spec >/dev/null
  echo s > "factory/jobs/$id/spec.md"; J advance "$id" build >/dev/null
  build_commit "$id" "${1//\//-}.txt" c; to_review "$id"; review "$id" 1 code PASS; J advance "$id" approve >/dev/null
  printf 'APPROVE\n\n## Why\nok\n' > "factory/jobs/$id/decision.md"
  J merge "$id"
}

t_feature_mid_review() {
  new_repo midreview; mkdir -p .scratch/feat/issues
  printf '# Feat\n\n**Branch:** feature/m\n' > .scratch/feat/spec.md
  for n in 01 02 03; do printf '# %s: T\n\n**Status:** ready-for-agent\n\nc\n' $n > .scratch/feat/issues/$n-t.md; done
  ticket 09 Plain; commit_all
  set_config feature_review_every 2
  local f=factory/jobs/_features out
  out=$(merge_feature_job feat/01)
  check "first merge: no review yet" "[$(grep -c 'mid-feature' <<< "$out")]" "[0]" || return 1
  out=$(merge_feature_job feat/02)
  check "second merge starts it" "$out" "feature/m: 2 jobs merged since the last feature review" &&
  check "started" "$out" "mid-feature review started" &&
  check "mid mode" "$(tail -3 "$SPECS")" "Mode: mid-feature (tickets still open: feat/03" &&
  check "writes the integration file" "$(tail -3 "$SPECS")" "Write: $PWD/$f/feature-m-integration.md" &&
  check "detached worktree on the branch" "$(git -C .worktrees/_midreview-feature-m rev-parse HEAD)" "$(git rev-parse feature/m)" &&
  check "counted" "$(python3 -c "import json; print(json.load(open('$f/feature-m-mid.json'))['merged'])")" "2" || return 1
  local plain; plain=$(J create f/09); J start "$plain" intake >/dev/null
  check "no notes before the file exists" "[$(tail -3 "$SPECS" | grep -c 'Integration notes')]" "[0]" || return 1
  printf 'VERDICT: CHANGES\n\n## Findings\n1. a.txt:1 use one name\n' > $f/feature-m-integration.md
  local id; id=$(J create feat/03); J start "$id" intake >/dev/null
  check "intake points to it" "$(tail -3 "$SPECS")" "Integration notes: $PWD/$f/feature-m-integration.md" || return 1
  J start "$plain" intake >/dev/null
  check "a job on the base doesn't" "[$(tail -3 "$SPECS" | grep -c 'Integration notes')]" "[0]" || return 1
  intake "$id" medium none; factory/bin/route "$id" >/dev/null; J advance "$id" spec >/dev/null; J start "$id" spec >/dev/null
  check "spec points to it" "$(tail -3 "$SPECS")" "Integration notes:" || return 1
  echo s > "factory/jobs/$id/spec.md"; J advance "$id" build >/dev/null; J start "$id" builder >/dev/null
  check "builder points to it" "$(tail -3 "$SPECS")" "Integration notes:" || return 1
  set_config feature_review_every 1
  build_commit "$id" c3.txt c; to_review "$id"; review "$id" 1 code PASS; J advance "$id" approve >/dev/null
  printf 'APPROVE\n\n## Why\nok\n' > "factory/jobs/$id/decision.md"
  out=$(J merge "$id")
  check "last ticket: finish instead" "$out" "every ticket for feature/m is done" &&
  check "no mid review then" "[$(grep -c 'mid-feature' <<< "$out")]" "[0]" || return 1
  J finish feature/m >/dev/null; J feature-review feature/m >/dev/null
  check "final review reads the notes" "$(tail -3 "$SPECS")" "Integration notes from the mid-feature reviews: $PWD/$f/feature-m-integration.md" &&
  check "final mode" "$(tail -3 "$SPECS")" "Mode: final" || return 1
  printf 'VERDICT: PASS\n\n## Findings\nNone.\n' > $f/feature-m-review.md
  check "merged" "$(J finish feature/m)" "feature/m: merged into master" &&
  check "mid worktree gone" "$(test -d .worktrees/_midreview-feature-m && echo yes || echo no)" "no"
}

t_feature_mid_review_off() {
  new_repo midreviewoff; mkdir -p .scratch/feat/issues
  printf '# Feat\n\n**Branch:** feature/o\n' > .scratch/feat/spec.md
  for n in 01 02; do printf '# %s: T\n\n**Status:** ready-for-agent\n\nc\n' $n > .scratch/feat/issues/$n-t.md; done
  commit_all
  check "default off" "[$(merge_feature_job feat/01 | grep -c 'mid-feature')]" "[0]" &&
  check "no state" "[$(ls factory/jobs/_features 2>/dev/null)]" "[]"
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

t_resume_records_needs_a_human_results() {
  new_repo needsresult; ticket 01 One; ticket 02 Two; commit_all
  local id; id=$(J create f/01); intake "$id" high security
  factory/bin/route "$id" >/dev/null; J advance "$id" spec >/dev/null
  printf '# S\n\n## Needs a human\n- count private orgs: psql -c ...; done when 0\n' > "factory/jobs/$id/spec.md"
  J advance "$id" build >/dev/null
  printf 'spec ok\n- count private orgs: 0 rows\n' | J resume "$id" >/dev/null &&
  check "headline kept" "$(cat "factory/jobs/$id/accepted.md")" "risk high): spec ok" &&
  check "result under it" "$(cat "factory/jobs/$id/accepted.md")" $'spec ok\n  - count private orgs: 0 rows' &&
  check "result in job.json" "$(field "$id" "d['accepted'][0]['answers']")" "['count private orgs: 0 rows']" || return 1
  local id2; id2=$(J create f/02); intake "$id2" high security
  factory/bin/route "$id2" >/dev/null; J advance "$id2" spec >/dev/null
  printf '# S\n\n## Needs a human\n- count private orgs: psql -c ...; done when 0\n' > "factory/jobs/$id2/spec.md"
  J advance "$id2" build >/dev/null
  check "warns when no result was given" "$(J resume "$id2" 2>&1 </dev/null)" "no result recorded for 1 Needs-a-human item"
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

t_dashboard_subscriptions() {
  new_repo dashsubs; commit_all
  local other="$TMP_ROOT/dashsubs/other"
  mkdir -p "$other/factory/jobs/001-x" factory/jobs/001-a factory/jobs/_features
  echo '{"id":"001-a","stage":"merged","started":"2026-11-01T00:00:00Z","cost_usd":2,"cost_by_agent":{"claude":1.5,"codex":0.5},"history":[1]}' > factory/jobs/001-a/job.json
  echo '{"id":"001-x","stage":"build","started":"2026-11-02T00:00:00Z","cost_usd":1}' > "$other/factory/jobs/001-x/job.json"
  echo '{"checked":"abc"}' > factory/jobs/_features/f.json
  export XDG_CONFIG_HOME="$TMP_ROOT/dashsubs/config"
  local q='import importlib.machinery as m, importlib.util as u, json
l = m.SourceFileLoader("d", "factory/bin/dashboard"); d = u.module_from_spec(u.spec_from_loader("d", l)); l.exec_module(d)
print(json.dumps(d.subscriptions()))'
  check "no config: nothing to serve" "$(python3 -c "$q")" "null" || return 1
  mkdir -p "$XDG_CONFIG_HOME/factory"
  printf '{"subscriptions":[{"agent":"claude","usd_per_month":100}],"projects":["%s","%s","%s/gone"]}' \
    "$other" "$PWD" "$TMP_ROOT" > "$XDG_CONFIG_HOME/factory/subscriptions.json"
  local out; out=$(python3 -c "$q")
  local names; names=$(python3 -c "import json,sys; print(','.join(p['name'] for p in json.loads(sys.argv[1])['projects']))" "$out")
  check "this repo first, listed repos once each" "$names" "repo,other,gone" &&
  check "subscriptions passed through" "$out" '"usd_per_month": 100' &&
  check "jobs of every repo, cost fields only" "$out" '"id": "001-x", "stage": "build", "started": "2026-11-02T00:00:00Z", "ended": null, "cost_usd": 1, "cost_by_agent": null' &&
  check "no history sent" "[$(grep -c history <<< "$out")]" "[0]" &&
  check "_features is not a job" "[$(grep -c '"checked"' <<< "$out")]" "[0]" &&
  check "a listed repo without a factory is flagged" "$out" '"name": "gone", "jobs": [], "missing": true'
  unset XDG_CONFIG_HOME
}

t_dashboard_outside() {
  new_repo dashout; commit_all
  local h="$TMP_ROOT/dashout/home"; local cl="$h/.claude/projects/-x" cx="$h/.codex/sessions/2026/11/14"
  local acct="$h/.config/orca/codex-accounts/a/home/sessions/2026/11/14"
  mkdir -p "$cl/s1/subagents" "$cx" "$acct"
  local use='"usage":{"input_tokens":1000000,"output_tokens":0}'
  # A plain session; a resumed copy repeating its message; a factory job's session; an unpriced model.
  printf '%s\n' '{"type":"user","cwd":"/w/app","message":{"role":"user","content":"hi"}}' \
    "{\"type\":\"assistant\",\"timestamp\":\"2026-11-14T12:00:00Z\",\"message\":{\"id\":\"m1\",\"model\":\"claude-opus-5-5\",$use}}" > "$cl/s1.jsonl"
  cp "$cl/s1.jsonl" "$cl/s2.jsonl"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"Job folder: /r/factory/jobs/001-a/"}}' \
    "{\"type\":\"assistant\",\"timestamp\":\"2026-11-14T12:00:00Z\",\"message\":{\"id\":\"m2\",\"model\":\"claude-opus-5-5\",$use}}" > "$cl/s3.jsonl"
  echo "{\"type\":\"assistant\",\"timestamp\":\"2026-11-14T12:00:00Z\",\"message\":{\"id\":\"m3\",\"model\":\"claude-x\",\"usage\":{\"input_tokens\":500}}}" > "$cl/s1/subagents/agent-1.jsonl"
  # Codex: running totals across a month boundary; a shorter copy of it in Orca's account home.
  local tc='{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":%s,"cached_input_tokens":0,"output_tokens":%s,"total_tokens":%s}}}}\n'
  { echo '{"timestamp":"2026-11-14T12:00:00Z","type":"session_meta","payload":{"id":"c1","cwd":"/w/api"}}'
    echo '{"timestamp":"2026-11-14T12:00:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}'
    printf "$tc" 2026-11-14T12:00:00Z 1000000 0 1000000; printf "$tc" 2026-11-14T12:00:01Z 1000000 0 1000000
    printf "$tc" 2026-12-14T12:00:00Z 2000000 100000 2100000; } > "$cx/rollout-c1.jsonl"
  head -3 "$cx/rollout-c1.jsonl" > "$acct/rollout-c1.jsonl"
  local q='import importlib.machinery as m, importlib.util as u, json
l = m.SourceFileLoader("d", "factory/bin/dashboard"); d = u.module_from_spec(u.spec_from_loader("d", l)); l.exec_module(d)
import os, pathlib
r = d.Outside().scan(); before = d.CACHE.stat().st_mtime_ns; r2 = d.Outside().scan()
untouched = d.CACHE.stat().st_mtime_ns == before
for f in pathlib.Path(os.environ["HOME"], ".claude/projects/-x").glob("s[12].jsonl"): f.unlink()
r3 = d.Outside().scan()
print(json.dumps({"untouched": untouched, "kept": r3 == r, "months": {k: {a: round(v, 2) for a, v in x.items()} for k, x in sorted(r["months"].items())},
  "cwds": [c["cwd"] + ":" + str(c["sessions"]) for c in r["by_cwd"]], "unpriced": r["unpriced"],
  "factory": r["factory_sessions"], "cached": r == r2}, sort_keys=True))'
  local out; out=$(env -u CODEX_HOME -u CLAUDE_CONFIG_DIR -u XDG_CACHE_HOME HOME="$h" python3 -c "$q")
  check "a resumed copy counts once, codex growth lands in its month" "$out" '"months": {"2026-11": {"claude": 4.0, "codex": 2.0}, "2026-12": {"claude": 0.0, "codex": 3.0}}' &&
  check "factory sessions left out" "$out" '"factory": 1' &&
  check "by directory, costliest first, a copy adds no session" "$out" '"cwds": ["/w/api:1", "/w/app:1"]' &&
  check "unpriced model reported by month" "$out" '"unpriced": {"2026-11": {"claude-x": 500}}' &&
  check "second pass from the cache agrees" "$out" '"cached": true' &&
  check "cache written" "[$(test -s "$h/.cache/factory/usage.json" && echo y)]" "[y]" &&
  check "nothing new, cache not rewritten" "$out" '"untouched": true' &&
  check "deleted transcripts keep counting" "$out" '"kept": true'
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

t_gate_refuses_outside_gate_stage() {
  new_repo gatestage; ticket 01 One; commit_all
  local id; id=$(to_build 01 low none); build_commit "$id" y.txt y
  local out; out=$(factory/bin/gate "$id" 2>&1); local code=$?
  check "refuses in build" "$out" "$id is in build, not gate" &&
  check "says how" "$out" "job advance $id gate" &&
  check "exit 2" "$code" "2" &&
  check "no checks.md" "[$(ls "factory/jobs/$id/round-1/" | grep -c checks)]" "[0]" || return 1
  ready "$id"; J advance "$id" gate >/dev/null
  check "runs in gate" "$(factory/bin/gate "$id")" "GATE: PASS" || return 1
  J advance "$id" review >/dev/null
  check "refuses in review" "$(factory/bin/gate "$id" 2>&1)" "is in review, not gate" || return 1
  review "$id" 1 code PASS; J advance "$id" approve >/dev/null
  printf 'APPROVE\n\n## Why\nok\n' > "factory/jobs/$id/decision.md"
  check "job merge's --merge gate still runs" "$(J merge "$id")" "merged factory/$id into master" &&
  check "merge checks written" "$(head -1 "factory/jobs/$id/round-1/merge-checks.md")" "GATE: PASS"
}

t_gate_failures_readable() {
  new_repo gatefail; ticket 01 One; commit_all
  local id; id=$(to_build 01 low none); build_commit "$id" y.txt y; ready "$id"; J advance "$id" gate >/dev/null
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
  for j in "$a" "$b"; do build_commit "$j" y.txt y; ready "$j"; J advance "$j" gate >/dev/null; done
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

overlap_setup() {  # overlap_setup <name>: jobs A (builds src/a.ts) and B (its spec names src/a.ts); sets A, B
  new_repo "$1"; mkdir -p src; echo a > src/a.ts; echo b > src/b.ts; ticket 01 One; ticket 02 Two; commit_all
  A=$(to_build 01 low none) || return 1
  build_commit "$A" src/a.ts a2
  B=$(to_build 02 low none) || return 1
  printf '# Spec\n\n## Context\nThe parser lives in `src/a.ts:12`, see also the docs and/or README.\n' > "factory/jobs/$B/spec.md"
}

t_overlap_waits() {
  local A B; overlap_setup overlap-wait || return 1
  check "next waits" "$(J next "$B")" "$B: wait: overlaps $A (src/a.ts)" &&
  check "start refuses" "$(J start "$B" builder 2>&1)" "wait: overlaps $A (src/a.ts)" &&
  check "no worker started for B" "[$(grep "$B builder" "$CALLS" 2>/dev/null)]" "[]" &&
  check "A, which has changes, never waits on B" "$(J next "$A")" "$A: start: factory/bin/job start $A builder" &&
  set_config overlap_wait false &&
  check "knob off: next starts" "$(J next "$B")" "$B: start: factory/bin/job start $B builder" &&
  check "knob off: start works" "$(J start "$B" builder)" "started builder"
}

t_overlap_none_starts() {
  new_repo overlap-none; mkdir -p src; echo a > src/a.ts; echo b > src/b.ts; ticket 01 One; ticket 02 Two; commit_all
  local A B; A=$(to_build 01 low none) && B=$(to_build 02 low none) || return 1
  check "neither has changes: no wait either way" "$(J next "$A"; J next "$B")" "$B: start:" || return 1
  build_commit "$A" src/a.ts a2
  printf '# Spec\n\n## Context\nChange **src/b.ts** and add `src/new/c.ts`.\n\n## Out of scope\nDon'"'"'t touch `src/a.ts`.\n' > "factory/jobs/$B/spec.md"
  check "no overlap: next starts" "$(J next "$B")" "$B: start: factory/bin/job start $B builder" || return 1
  echo b2 > ".worktrees/$A/src/b.ts"
  check "uncommitted change counts" "$(J next "$B")" "$B: wait: overlaps $A (src/b.ts)" &&
  check "top-level directory is too broad" "$(printf '# Spec\nAll of `src/`.\n' > "factory/jobs/$B/spec.md"; J next "$B")" "$B: start:"
}

t_overlap_clears_when_merged() {
  local A B; overlap_setup overlap-merged || return 1
  check "waits while A builds" "$(J next "$B")" "wait: overlaps $A" || return 1
  to_review "$A"; review "$A" 1 code PASS
  check "still waits in review" "$(J next "$B")" "wait: overlaps $A" || return 1
  J advance "$A" approve >/dev/null; printf 'APPROVE\n\n## Why\nok\n' > "factory/jobs/$A/decision.md"
  check "A merges" "$(J merge "$A")" "merged factory/$A" &&
  check "B starts after A merged" "$(J next "$B")" "$B: start: factory/bin/job start $B builder" &&
  check "start works" "$(J start "$B" builder)" "started builder"
}

# ---- protected-only tickets: work no builder may do stops before the build ----

protected_intake() {  # protected_intake <job> <file>...: intake says the whole change is in protected files
  local id="$1"; shift
  { printf 'DECISION: PROTECTED\nRISK: low\nSURFACES: none\nRESCOPED: no\nSIZE: small\nSPLIT: no\n\n'
    printf '## Summary\n- only the checks\n\n## Why\nThe gate script needs a new step.\n\n## Protected files\n'
    for f in "$@"; do printf -- '- `%s`\n' "$f"; done
    printf '\n## Follow-ups\nNone.\n'; } > "factory/jobs/$id/intake.md"
}

to_spec() {  # to_spec <ticket>: create .. spec (medium risk, so the spec writer runs); prints the job id
  local id; id=$(J create "f/$1") || return 1
  intake "$id" medium none
  factory/bin/route "$id" >/dev/null && J advance "$id" spec >/dev/null || return 1
  echo "$id"
}

t_protected_intake_needs_human() {
  new_repo protintake; mkdir -p src; echo a > src/a.ts; ticket 01 One; commit_all
  local id; id=$(J create f/01) || return 1
  J start "$id" intake >/dev/null
  check "intake prompt names the protected paths" "$(cat "$SPECS")" 'Protected paths: `factory/checks.sh`, `factory/config.json`, `factory/agents/*`' || return 1
  protected_intake "$id" src/a.ts
  check "a buildable file is refused" "$(J advance "$id" needs-human 2>&1)" "src/a.ts doesn't match config.json protected_paths" || return 1
  protected_intake "$id" factory/checks.sh factory/agents/builder.md
  check "next says needs-human" "$(J next "$id")" "advance: factory/bin/job advance $id needs-human" &&
  J advance "$id" needs-human >/dev/null &&
  check "stage" "$(field "$id" "d['stage']")" "needs-human" &&
  check "label" "$(status_of 01)" "ready-for-human" &&
  check "reason in decision.md" "$(cat "factory/jobs/$id/decision.md")" \
    "Only protected files: factory/checks.sh, factory/agents/builder.md; a human makes this change" &&
  check "reason on the ticket" "$(cat .scratch/f/issues/01-t.md)" "### Factory: needs a human" &&
  check "intake's why too" "$(cat "factory/jobs/$id/decision.md")" "The gate script needs a new step." &&
  check "no spec" "[$(ls "factory/jobs/$id/spec.md" 2>/dev/null)]" "[]" &&
  check "no worktree" "[$(ls -d ".worktrees/$id" 2>/dev/null)]" "[]" &&
  check "no spec worker" "[$(cat "$CALLS" 2>/dev/null | grep -c "$id spec")]" "[0]" &&
  check "waits for a human" "$(J next "$id")" "wait: human" || return 1
  echo "Made by hand in abc123." | J reject "$id" >/dev/null &&
  check "closed as done" "$(status_of 01)" "done" &&
  check "not wontfix" "$(cat .scratch/f/issues/01-t.md)" "### Factory: closed, a human made this change" &&
  check "stage rejected" "$(field "$id" "d['stage']")" "rejected"
}

t_protected_intake_feedback_goes_back_to_intake() {
  new_repo protintakefb; ticket 01 One; commit_all
  local id; id=$(J create f/01) || return 1
  protected_intake "$id" factory/checks.sh
  J advance "$id" needs-human >/dev/null || return 1
  check "feedback rewinds to intake" "$(echo "It needs src/ too." | J feedback "$id")" "back to intake" &&
  check "stage" "$(field "$id" "d['stage']")" "intake" &&
  check "flag cleared" "$(field "$id" "d.get('protected_only')")" "None"
}

t_protected_spec_stops_before_build() {
  new_repo protspec; ticket 01 One; commit_all
  local id; id=$(to_spec 01) || return 1
  printf '# Spec\n\n## Requirements\n1. Add a step to `factory/checks.sh`.\n2. Mention it in factory/agents/builder.md.\n\n## Out of scope\n- `src/a.ts`\n' \
    > "factory/jobs/$id/spec.md"
  check "next says needs-human" "$(J next "$id")" "advance: factory/bin/job advance $id needs-human" &&
  check "build refused" "$(J advance "$id" build 2>&1)" "every path spec.md names is protected (factory/checks.sh, factory/agents/builder.md)" &&
  J advance "$id" needs-human >/dev/null &&
  check "stage" "$(field "$id" "d['stage']")" "needs-human" &&
  check "no build round" "$(field "$id" "d['round']")" "0" &&
  check "label" "$(status_of 01)" "ready-for-human" &&
  check "reason" "$(cat "factory/jobs/$id/decision.md")" "Only protected files: factory/checks.sh, factory/agents/builder.md; a human makes this change" &&
  check "no builder" "[$(cat "$CALLS" 2>/dev/null | grep -c "$id builder")]" "[0]"
}

t_protected_mixed_spec_builds() {
  new_repo protmixed; mkdir -p src; echo a > src/a.ts; ticket 01 One; commit_all
  local id; id=$(to_spec 01) || return 1
  printf '# Spec\n\n## Requirements\n1. Change `src/a.ts`.\n2. The gate in `factory/checks.sh` stays as it is.\n' > "factory/jobs/$id/spec.md"
  check "next says build" "$(J next "$id")" "advance: factory/bin/job advance $id build" &&
  check "needs-human refused" "$(J advance "$id" needs-human 2>&1)" "advance it to build" &&
  J advance "$id" build >/dev/null &&
  check "stage" "$(field "$id" "d['stage']")" "build"
}

t_protected_off_without_config() {
  new_repo protoff; ticket 01 One; ticket 02 Two; set_config protected_paths '[]'; commit_all
  local id; id=$(to_spec 01) || return 1
  check "no protected note in prompts" "[$(cat "$SPECS" 2>/dev/null | grep -c 'Protected paths')]" "[0]" || return 1
  J start "$id" spec >/dev/null
  check "spec prompt without it too" "[$(grep -c 'Protected paths' "$SPECS")]" "[0]" &&
  printf '# Spec\n\n## Requirements\n1. Add a step to `factory/checks.sh`.\n' > "factory/jobs/$id/spec.md" &&
  check "next says build" "$(J next "$id")" "advance: factory/bin/job advance $id build" &&
  J advance "$id" build >/dev/null &&
  check "stage" "$(field "$id" "d['stage']")" "build" || return 1
  local id2; id2=$(J create f/02) || return 1
  protected_intake "$id2" factory/checks.sh
  check "PROTECTED with nothing protected is refused" "$(J advance "$id2" needs-human 2>&1)" "doesn't match config.json protected_paths"
}

t_protected_spec_from_intake_stops() {
  new_repo protskip; ticket 01 One; commit_all
  local id; id=$(J create f/01) || return 1
  printf 'DECISION: ACCEPT\nRISK: low\nSURFACES: none\nRESCOPED: no\nSIZE: small\nSPLIT: no\n\n## Summary\n- ok\n\n## Scope\nAdd a lint step to `factory/checks.sh`.\n\n## Acceptance criteria\n1. `factory/checks.sh` runs the lint.\n\n## Follow-ups\nNone.\n' \
    > "factory/jobs/$id/intake.md"
  factory/bin/route "$id" >/dev/null && J advance "$id" spec >/dev/null || return 1
  check "stops instead of building" "$(field "$id" "d['stage']")" "needs-human" &&
  check "reason" "$(cat "factory/jobs/$id/decision.md")" "Only protected files: factory/checks.sh" &&
  check "no build round" "$(field "$id" "d['round']")" "0"
}

# ---- labels.factory: only issues handed to the factory run --------------------

FACTORY_LABELS='{"queue": "ready-for-agent", "needs_info": "needs-info", "needs_human": "ready-for-human", "returned": "needs-triage", "wontfix": "wontfix", "factory": "factory"}'

needs_info() {  # needs_info <job>: intake asks a question; the job waits for the author
  printf 'DECISION: NEEDS-INFO\nRISK: low\nSURFACES: none\nRESCOPED: no\nSIZE: small\nSPLIT: no\n\n## Summary\n- unclear\n\n## Questions\n1. Which page?\n\n## Follow-ups\nNone.\n' \
    > "factory/jobs/$1/intake.md"
  J advance "$1" needs-info >/dev/null
}

add_follow_up() {  # add_follow_up <job>: intake.md lists one follow-up
  python3 - "factory/jobs/$1/intake.md" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace("## Follow-ups\nNone.", "## Follow-ups\n- Do the other half: it was too big."))
PY
}

t_factory_label_off_by_default() {
  new_repo factorylabeloff; ticket 01 One; ticket 02 Two '**Labels:** factory'; commit_all
  check "template default is off" "$(python3 -c "import json; print(json.load(open('factory/config.json'))['labels']['factory'])")" "None" &&
  check "every queued ticket is new" "$(J queue | awk '$1=="new"{print $2}' | xargs)" "f/01 f/02" &&
  check "no skip row" "[$(J queue | grep -c skip)]" "[0]" &&
  check "tracker prints no factory label" "[$(J tracker | grep -c 'label factory')]" "[0]" &&
  check "create takes an unlabeled ticket" "$(J create f/01)" "001"
}

t_factory_label_local() {
  new_repo factorylabel
  ticket 01 Mine '**Labels:** factory'; ticket 02 Theirs; ticket 03 Both '**Labels:** ui, `factory`'
  set_config labels "$FACTORY_LABELS"; commit_all
  local q; q=$(J queue)
  check "labeled tickets are new" "$(echo "$q" | awk '$1=="new"{print $2}' | xargs)" "f/01 f/03" &&
  check "unlabeled one skipped with the reason" "$q" $'skip\tf/02\t-\t-\tno factory label: left to people' &&
  check "selection says so too" "$(J queue f/02)" $'skip\tf/02\t-\t-\tno factory label: left to people' &&
  J queue --clear >/dev/null &&
  check "create refuses" "$(J create f/02 2>&1)" "isn't labeled factory: the factory only takes issues labeled both ready-for-agent and factory" &&
  check "and says how to hand it over" "$(J create f/02 2>&1)" "a \`**Labels:** factory\` line in the ticket" &&
  check "tracker prints it" "$(J tracker)" "label factory factory" || return 1
  # f/01 runs through, leaving and re-entering the queue twice; the factory label stays put.
  local id; id=$(J create f/01) || return 1
  needs_info "$id"
  check "waits as needs-info" "$(status_of 01)" "needs-info" &&
  check "still listed while waiting" "$(J queue)" $'wait\tf/01\t'"$id"$'\tneeds-info\twaiting for the author' || return 1
  echo "On the start page." | J reply f/01 >/dev/null
  check "answer resumes it" "$(J queue)" $'resume\tf/01\t'"$id"$'\tneeds-info\tauthor replied' || return 1
  J advance "$id" intake >/dev/null
  check "back in the queue" "$(status_of 01)" "ready-for-agent" || return 1
  intake "$id" low none; factory/bin/route "$id" >/dev/null && J advance "$id" spec >/dev/null
  echo "# Spec" > "factory/jobs/$id/spec.md"; J advance "$id" build >/dev/null
  build_commit "$id" y.txt y; to_review "$id"; review "$id" 1 code PASS; J advance "$id" approve >/dev/null
  printf 'ESCALATE\n\n## Why\n- Unsure.\n' > "factory/jobs/$id/decision.md"; J advance "$id" needs-human >/dev/null
  check "waits for a human" "$(status_of 01)" "ready-for-human" &&
  check "listed while it waits" "$(J queue)" $'wait\tf/01\t'"$id"$'\tneeds-human' || return 1
  echo "Rename it." | J feedback "$id" >/dev/null
  check "feedback puts it back" "$(status_of 01)" "ready-for-agent" &&
  check "and it runs" "$(J queue)" $'resume\tf/01\t'"$id"$'\tbuild' || return 1
  build_commit "$id" y.txt y2; to_review "$id"; review "$id" 2 code PASS; J advance "$id" approve >/dev/null
  printf 'APPROVE\n\n## Why\nok\n' > "factory/jobs/$id/decision.md"
  check "merged" "$(J merge "$id")" "merged factory/$id into master" &&
  check "done" "$(status_of 01)" "done" &&
  check "factory label never touched" "$(grep -c '^\*\*Labels:\*\* factory$' .scratch/f/issues/01-t.md)" "1"
}

t_factory_label_from_triage_doc() {
  new_repo factorylabeldoc; ticket 01 Mine '**Labels:** agent-ok'; ticket 02 Theirs '**Labels:** factory'
  mkdir -p docs/agents
  printf '| Role | Label |\n|---|---|\n| `ready-for-agent` | `ready-for-agent` |\n| `factory` | `agent-ok` |\n' > docs/agents/triage-labels.md
  commit_all
  local q; q=$(J queue)
  check "mapped label counts" "$q" $'new\tf/01' &&
  check "the config's name doesn't" "$q" $'skip\tf/02\t-\t-\tno agent-ok label: left to people'
}

t_factory_label_follow_ups() {
  new_repo factorylabelfollow; ticket 01 One '**Labels:** factory'
  set_config labels "$FACTORY_LABELS"; commit_all
  local id; id=$(J create f/01); intake "$id" low none; add_follow_up "$id"
  factory/bin/route "$id" >/dev/null; J advance "$id" spec >/dev/null
  local t; t=$(cat .scratch/f/issues/02-*.md)
  check "needs triage" "$t" "**Status:** needs-triage" &&
  check "handed to the factory" "$t" "**Labels:** factory" || return 1
  sed -i 's/needs-triage/ready-for-agent/' .scratch/f/issues/02-*.md
  check "triaged, it comes back to the factory" "$(J queue)" $'new\tf/02' || return 1
  sed -i '/^\*\*Labels:\*\*/d' .scratch/f/issues/01-t.md  # a person takes f/01 back
  check "a job whose label is gone stops" "$(J queue)" $'skip\tf/01\t'"$id"$'\tspec\tissue is closed or no longer labeled both ready-for-agent and factory'
}

gh_labels_of() { python3 -c "import json; print(sorted(l['name'] for l in json.load(open('$GH/issue-$1.json'))['labels']))"; }

t_gh_factory_label() {
  new_gh_repo ghfactorylabel; set_config labels "$FACTORY_LABELS"
  gh_issue 1 Mine; gh_issue_set 1 'i["labels"].append({"name": "factory"})'
  gh_issue 2 Theirs
  local q; q=$(J queue)
  check "asks GitHub for both labels" "$(grep 'issue list' "$GH_LOG" | head -1)" "--label ready-for-agent --label factory" &&
  check "labeled one is new" "$q" $'new\t1' &&
  check "other skipped" "$q" $'skip\t2\t-\t-\tno factory label: left to people' &&
  check "create refuses" "$(J create 2 2>&1)" "issue #2 isn't labeled factory" || return 1
  local id; id=$(J create 1) || return 1
  needs_info "$id"
  check "waiting label swapped, factory kept" "$(gh_labels_of 1)" "['factory', 'needs-info']" &&
  check "listed while waiting" "$(J queue)" $'wait\t1\t'"$id"$'\tneeds-info' || return 1
  J advance "$id" intake >/dev/null; intake "$id" low none; add_follow_up "$id"
  factory/bin/route "$id" >/dev/null; J advance "$id" spec >/dev/null
  check "follow-up filed with the factory label" "$(grep 'issue create' "$GH_LOG")" "--label needs-triage --label factory" &&
  check "follow-up carries both" "$(gh_labels_of 3)" "['factory', 'needs-triage']" &&
  check "back in the queue" "$(gh_labels_of 1)" "['factory', 'ready-for-agent']" || return 1
  echo "# Spec" > "factory/jobs/$id/spec.md"; J advance "$id" build >/dev/null
  build_commit "$id" y.txt y
  (cd ".worktrees/$id" && git push -q -u origin "factory/$id" 2>/dev/null &&
   gh pr create --draft --base master --head "factory/$id" --title t --body b >/dev/null)
  to_review "$id"; review "$id" 1 code PASS; J advance "$id" approve >/dev/null
  printf 'APPROVE\n\n## Why\nok\n' > "factory/jobs/$id/decision.md"
  check "merged" "$(J merge "$id" 2>&1)" "merged PR #7" &&
  check "the factory never edits its label" "[$(grep 'issue edit' "$GH_LOG" | grep -c 'factory')]" "[0]"
}

t_update_adds_nested_config_key() {
  new_repo updatecfg
  python3 - <<'PY'
import json; p = "factory/config.json"; c = json.load(open(p))
del c["labels"]["factory"]; c["labels"]["queue"] = "agent-go"; json.dump(c, open(p, "w"), indent=2)
PY
  commit_all
  local out; out=$(factory/bin/update "$FACTORY_SRC/.." --force 2>&1)
  check "says it added the key" "$out" "labels.factory" &&
  # The template's value: null in the template, an installation's own when its tests run.
  local want; want=$(python3 -c "import json; print(repr(json.load(open('$FACTORY_SRC/config.json'))['labels'].get('factory')))")
  check "added with the template's value" "$(python3 -c "import json; print(json.load(open('factory/config.json'))['labels'])")" "'factory': $want" &&
  check "own value kept" "$(python3 -c "import json; print(json.load(open('factory/config.json'))['labels']['queue'])")" "agent-go"
}

# ---- findings: severities, stable ids, the builder's answers, disputes --------

rv() {  # rv <job> <round> <lens> <PASS|CHANGES> <earlier findings lines> <findings lines>
  printf 'VERDICT: %s\n\n## Summary\n- ok\n\n## Standards\nNone.\n\n## Spec\nMet.\n\n## Earlier findings\n%s\n\n## Findings\n%s\n' \
    "$4" "$5" "$6" > "factory/jobs/$1/round-$2/review-$3.md"
}

built() {  # built <job> <review findings lines>: a READY build.md with these answers
  printf 'STATUS: READY\n\n# Build\n\n## Summary\n- ok\n\n## Self-review\nChecked.\nPre-review: no findings.\n\n## Review findings\n%s\n' \
    "$2" > "factory/jobs/$1/build.md"
}

regate() {  # regate <job>: build → gate → review, with the build.md that is there
  J advance "$1" gate >/dev/null && factory/bin/gate "$1" >/dev/null && J advance "$1" review >/dev/null
}

t_findings_verdict_fits_severity() {
  new_repo sev; ticket 01 One; commit_all
  local id; id=$(to_build 01 medium none); build_commit "$id" y.txt y; to_review "$id"
  rv "$id" 1 code CHANGES "" "None."
  check "CHANGES needs a blocker or a should" "$(J advance "$id" build 2>&1)" "no finding is a blocker or a should" || return 1
  rv "$id" 1 code CHANGES "" "1. x.txt:1 old format"
  check "a finding without id and severity doesn't count" "$(J advance "$id" build 2>&1)" "F<n> [blocker|should|nit]" || return 1
  rv "$id" 1 code CHANGES "" "F1 [nit] x.txt:1 rename it"
  check "only nits is a PASS" "$(J advance "$id" build 2>&1)" "a review with only nits is a PASS" || return 1
  rv "$id" 1 code PASS "" "- **F1** [blocker] x.txt:1 wrong result"
  check "PASS can't leave a blocker" "$(J advance "$id" approve 2>&1)" "it says PASS but leaves F1 open" || return 1
  rv "$id" 1 code PASS "" "F1 [nit] x.txt:1 rename it"
  check "nits pass" "$(J advance "$id" approve 2>&1)" "$id: approve"
}

t_findings_answered_next_round() {
  new_repo answers; ticket 01 One; commit_all
  local id; id=$(to_build 01 medium ui); build_commit "$id" y.txt y; to_review "$id"
  rv "$id" 1 code CHANGES "" $'F1 [blocker] x.txt:1 wrong result\nF2 [nit] x.txt:2 name it better'
  rv "$id" 1 ux CHANGES "" "F1 [should] page: the button says Go, make it Save"; review "$id" 1 ui PASS
  J advance "$id" build >/dev/null; build_commit "$id" y.txt y2
  built "$id" "ux F1 fixed: says Save"
  check "an open finding needs an answer" "$(J advance "$id" gate 2>&1)" "build.md doesn't answer code F1 (round-1/review-code.md)" || return 1
  built "$id" $'code F1 declined: later\nux F1 fixed: says Save'
  check "declined is for nits" "$(J advance "$id" gate 2>&1)" "\`declined\` is for nits" || return 1
  built "$id" $'code F1 disagree:\nux F1 fixed: says Save'
  check "disagree needs evidence" "$(J advance "$id" gate 2>&1)" "disagrees with code F1 without evidence" || return 1
  built "$id" $'code F1 fixed: guarded it\nux F1 disagree: Go is fine'
  check "ux findings are binding" "$(J advance "$id" gate 2>&1)" "the ux reviewer's findings are build instructions" || return 1
  built "$id" $'- code F1 fixed: guarded it\n- **ux F1** fixed: says Save'
  regate "$id" || return 1
  check "answers recorded" "$(field "$id" "d['answers']['2']['code F1']['status']")" "fixed" || return 1
  J start "$id" reviewer-code >/dev/null
  check "the reviewer is told what to answer" "$(cat "$SPECS")" \
    "Earlier findings to answer under \`## Earlier findings\`: F1 (round-1/review-code.md)" &&
  check "and where to number from" "$(cat "$SPECS")" "Number new findings from F3." || return 1
  rv "$id" 2 ux PASS "F1 resolved" "None."; rv "$id" 2 code PASS "" "None."
  check "an earlier finding needs a status" "$(J advance "$id" approve 2>&1)" \
    "doesn't say what became of F1 from round-1/review-code.md" || return 1
  check "next sends that to the reviewer" "$(J next "$id")" "review-code.md does not count" || return 1
  rv "$id" 2 code PASS "F1 still open: the guard misses 0" "None."
  check "still open is no PASS" "$(J advance "$id" approve 2>&1)" "it says PASS but leaves F1 open" || return 1
  rv "$id" 2 code PASS $'F1 resolved\n' "F3 [nit] y.txt:1 comment"
  check "resolved passes" "$(J advance "$id" approve 2>&1)" "$id: approve"
}

dispute_setup() {  # dispute_setup <name>: round 1 found code F1, the builder disputed it in round 2; sets id
  new_repo "$1"; ticket 01 One; commit_all
  id=$(to_build 01 medium none); build_commit "$id" y.txt y; to_review "$id"
  rv "$id" 1 code CHANGES "" "F1 [should] y.txt:1 handle the empty list"
  J advance "$id" build >/dev/null; build_commit "$id" z.txt z
  built "$id" "code F1 disagree: the caller in x.txt:1 never passes an empty list"
  regate "$id"
}

t_dispute_goes_to_a_human() {
  local id; dispute_setup dispute || return 1
  J start "$id" reviewer-code >/dev/null
  rv "$id" 2 code CHANGES "F1 still open: the API is public, other callers will" "None."
  check "next: a human decides" "$(J next "$id")" "advance: factory/bin/job advance $id needs-human" &&
  check "another round is refused" "$(J advance "$id" build 2>&1)" "code F1 stayed disputed: go to needs-human" || return 1
  J advance "$id" needs-human >/dev/null
  local why; why=$(cat "factory/jobs/$id/decision.md")
  check "the finding" "$why" "**code F1** [should] y.txt:1 handle the empty list" &&
  check "the builder's side" "$why" "- Builder: the caller in x.txt:1 never passes an empty list" &&
  check "the reviewer's side" "$why" "- Reviewer: the API is public, other callers will" &&
  check "round 2 of 3: no round was spent" "$(field "$id" "d['round'], d['round_limit']")" "(2, 3)" || return 1
  echo "The builder is right: the list is never empty." | J feedback "$id" >/dev/null
  build_commit "$id" z.txt z2; built "$id" ""
  check "after the human decided, nothing is owed" "$(regate "$id" && field "$id" "d['stage']")" "review" || return 1
  J start "$id" reviewer-code >/dev/null
  check "the reviewer gets no earlier findings" "[$(tail -1 "$SPECS" | grep -c 'Earlier findings to answer')]" "[0]" || return 1
  rv "$id" 3 code PASS "" "None."
  check "and the job goes on" "$(J advance "$id" approve 2>&1)" "$id: approve"
}

t_dispute_withdrawn_or_off() {
  local id; dispute_setup withdrawn || return 1
  rv "$id" 2 code PASS "F1 withdrawn: the builder is right, one caller" "None."
  check "the reviewer gives in: PASS" "$(J advance "$id" approve 2>&1)" "$id: approve" || return 1
  dispute_setup disputeoff || return 1; set_config max_disputes 0
  rv "$id" 2 code CHANGES "F1 still open: the API is public" "None."
  check "max_disputes 0: another round" "$(J advance "$id" build 2>&1)" "$id: build (round 3)"
}

t_diff_growth_flagged() {
  new_repo growth; ticket 01 One; commit_all
  local id; id=$(to_build 01 medium none); build_commit "$id" y.txt "$(seq 40)"; to_review "$id"
  check "round 1 is the baseline" "$(cat "factory/jobs/$id/round-1/diff.md")" "DIFF: OK" &&
  check "its size" "$(cat "factory/jobs/$id/round-1/diff.md")" "Round 1: 1 file(s), +40 -0." || return 1
  review "$id" 1 code CHANGES; J advance "$id" build >/dev/null
  build_commit "$id" z.txt "$(seq 30)"; to_review "$id"
  check "small growth is fine" "$(head -1 "factory/jobs/$id/round-2/diff.md")" "DIFF: OK" || return 1
  review "$id" 2 code CHANGES; J advance "$id" build >/dev/null
  build_commit "$id" w.txt "$(seq 60)"; to_review "$id"
  local diff; diff=$(cat "factory/jobs/$id/round-3/diff.md")
  check "the reviews grew the change" "$diff" "DIFF: GROWN" &&
  check "by how much" "$diff" "The change is 3.2x its size in round 1" &&
  check "kept in job.json" "$(field "$id" "d['diff_grown'], d['diff_sizes']['3']['insertions']")" "(True, 130)"
}

t_gh_pr_review_table() {
  new_gh_repo ghtable; gh_issue 1 One
  local id; id=$(gh_to_approve 1) || return 1
  rv "$id" 1 code CHANGES "" $'F1 [blocker] y.txt:1 wrong\nF2 [nit] y.txt:1 name'
  J advance "$id" build >/dev/null
  local body; body=$(python3 -c "import json; print(json.load(open('$GH/pr.json'))['body'])")
  check "the builder's text stays" "$body" "b" &&
  check "table in the PR" "$body" "## Factory review" &&
  check "round 1" "$body" "| code | CHANGES (1 blocker, 1 nit)<br>claude/sonnet:medium |" || return 1
  build_commit "$id" y.txt y2; (cd ".worktrees/$id" && git push -q origin "factory/$id")
  built "$id" "code F1 fixed: right now"; regate "$id" || return 1
  rv "$id" 2 code PASS "F1 resolved" "None."; J advance "$id" approve >/dev/null
  body=$(python3 -c "import json; print(json.load(open('$GH/pr.json'))['body'])")
  check "round 2 next to it" "$body" "| code | CHANGES (1 blocker, 1 nit)<br>claude/sonnet:medium | PASS<br>claude/sonnet:medium |" &&
  check "the gate row" "$body" "| gate | PASS | PASS |" &&
  check "one table, not two" "[$(grep -c '## Factory review' <<< "$body")]" "[1]"
}

# ---- report (factory/bin/report) -------------------------------------------
#
# A fake hub (python http.server) logs every gunzipped request body as one JSON
# line in $H/hub.log. $H/need_full makes it answer need_full true, $H/down makes
# it answer 500.

rpt_setup() {  # rpt_setup <name> [outside]: fresh repo, HOME, fake hub, hub.json
  new_repo "$1"; commit_all
  H="$TMP_ROOT/$1/home"; mkdir -p "$H/.config/factory"
  cat > "$TMP_ROOT/$1/fakehub.py" <<'EOF'
import gzip, http.server, os, sys
home = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if self.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
        with open(home + "/hub.log", "ab") as f:
            f.write(body + b"\n")
        with open(home + "/auth.log", "a") as f:
            f.write(self.headers.get("Authorization", "") + "\n")
        down = os.path.exists(home + "/down")
        out = b'{"ok":true,"need_full":%s}' % (b"true" if os.path.exists(home + "/need_full") else b"false")
        self.send_response(500 if down else 200)
        self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(home + "/port", "w").write(str(s.server_port))
s.serve_forever()
EOF
  python3 "$TMP_ROOT/$1/fakehub.py" "$H" & HUB_PID=$!
  trap 'kill $HUB_PID 2>/dev/null' EXIT
  for _ in $(seq 50); do [[ -s "$H/port" ]] && break; sleep 0.1; done
  printf '{"url":"http://127.0.0.1:%s","token":"tok","machine":"m1","outside":%s}\n' "$(cat "$H/port")" "${2:-false}" > "$H/.config/factory/hub.json"
}

rpt() {  # rpt <args>: run factory/bin/report with HOME in the temp dir
  env -u XDG_CONFIG_HOME -u XDG_CACHE_HOME -u FACTORY_HUB_URL -u FACTORY_HUB_TOKEN -u CLAUDE_CONFIG_DIR -u CODEX_HOME \
    HOME="$H" python3 factory/bin/report "$@"
}

rpt_job() {  # rpt_job <id> [stage]: a job folder with job.json, spec.md and round-1/review-code.md
  mkdir -p "factory/jobs/$1/round-1"
  echo "{\"id\":\"$1\",\"stage\":\"${2:-build}\",\"title\":\"t $1\"}" > "factory/jobs/$1/job.json"
  echo "spec of $1" > "factory/jobs/$1/spec.md"; echo "review of $1" > "factory/jobs/$1/round-1/review-code.md"
  echo "noise" > "factory/jobs/$1/build.log"
}

hub() {  # hub <python expression over b, the list of request bodies>
  python3 -c "
import json
b = [json.loads(l) for l in open('$H/hub.log')]
print($1)"
}

t_report_no_config() {
  new_repo rptnone; commit_all; H="$TMP_ROOT/rptnone/home"; mkdir -p "$H"
  rpt >/dev/null 2>&1; check "no hub.json: exit 2" "[$?]" "[2]"
  echo '{"url":"http://127.0.0.1:9"}' > /dev/null; mkdir -p "$H/.config/factory"
  echo '{"url":"http://127.0.0.1:9","token":"x"}' > "$H/.config/factory/hub.json"
  rpt >/dev/null 2>&1; check "hub unreachable: exit 1" "[$?]" "[1]"
}

t_report_push() {
  rpt_setup rptpush; rpt_job 001-a; rpt_job 002-b merged; mkdir -p factory/jobs/_features; echo '{}' > factory/jobs/_features/job.json
  local out; out=$(rpt 2>&1); check "first push exits 0 and says so" "[$?] $out" "[0] report: sent full: 1 repo(s), 2 job(s), 4 file(s)" &&
  check "full, with both jobs, their files and no logs" "$(hub 'b[0]["full"], b[0]["repos"][0]["job_ids"], sorted(b[0]["repos"][0]["jobs"][0]["files"])')" "True ['001-a', '002-b'] ['round-1/review-code.md', 'spec.md']" &&
  check "the first push carries the config" "$(hub '"prices_usd_per_mtok" in b[0]["repos"][0]["config"]')" "True" &&
  check "machine, token" "$(hub 'b[0]["machine"]') $(head -1 "$H/auth.log")" "m1 Bearer tok" || return 1
  rpt >/dev/null; check "nothing changed: a push with no jobs" "$(hub '(len(b), b[1]["full"], b[1]["repos"][0]["jobs"], "config" in b[1]["repos"][0], b[1]["repos"][0]["job_ids"])')" "(2, False, [], False, ['001-a', '002-b'])" || return 1
  echo "changed" > factory/jobs/001-a/round-1/review-code.md
  rpt >/dev/null; check "one file changed: only that file" "$(hub '[(j["id"], j["files"], j["files_removed"]) for j in b[2]["repos"][0]["jobs"]]')" "[('001-a', {'round-1/review-code.md': 'changed\n'}, [])]" || return 1
  rm factory/jobs/001-a/round-1/review-code.md
  rpt >/dev/null; check "a deleted file is files_removed" "$(hub '[(j["id"], j["files"], j["files_removed"]) for j in b[3]["repos"][0]["jobs"]]')" "[('001-a', {}, ['round-1/review-code.md'])]" || return 1
  rm -r factory/jobs/002-b
  rpt >/dev/null; check "a deleted job leaves job_ids" "$(hub 'b[4]["repos"][0]["job_ids"], b[4]["repos"][0]["jobs"]')" "['001-a'] []" || return 1
  echo '{"id":"001-a","stage":"' > factory/jobs/001-a/job.json   # half-written
  rpt >/dev/null; check "an unreadable job.json keeps the job, sends nothing" "$(hub 'b[5]["repos"][0]["job_ids"], b[5]["repos"][0]["jobs"]')" "['001-a'] []"
}

t_report_hub_down() {
  rpt_setup rptdown; rpt_job 001-a
  rpt >/dev/null; rpt >/dev/null; touch "$H/down"
  rpt >/dev/null 2>&1; check "hub answering 500: exit 1" "[$?]" "[1]" || return 1
  rm "$H/down"
  rpt >/dev/null; check "the next push after a failure is full" "$(hub '[x["full"] for x in b]')" "[True, False, False, True]"
}

t_report_need_full() {
  rpt_setup rptneed; rpt_job 001-a; touch "$H/need_full"
  rpt >/dev/null; rpt >/dev/null
  check "need_full on a delta push: a full one follows at once" "$(hub '[(x["full"], len(x["repos"][0]["jobs"])) for x in b]')" "[(True, 1), (False, 0), (True, 1)]"
}

t_report_identity() {
  rpt_setup rptid; rpt_job 001-a
  check "no origin: local/<dir>" "$(rpt --dry-run --no-outside | python3 -c 'import json,sys; r=json.load(sys.stdin)["repos"][0]; print(r["repo"], r["url"])')" "local/repo None" || return 1
  local cases='import importlib.machinery as m, importlib.util as u
l = m.SourceFileLoader("r", "factory/bin/report"); r = u.module_from_spec(u.spec_from_loader("r", l)); l.exec_module(r)
for s in ("git@github.com:Xuresch/factory.git", "https://github.com/Xuresch/factory", "https://github.com/Xuresch/factory.git/", "ssh://git@gitlab.example.com:2222/grp/sub/app.git"):
    print(r.parse_remote(s))'
  local out; out=$(python3 -c "$cases")
  check "ssh" "$out" "('Xuresch/factory', 'https://github.com/Xuresch/factory')" &&
  check "https without .git" "$out" "('Xuresch/factory', 'https://github.com/Xuresch/factory')" &&
  check "another host: last two segments, no url" "$out" "('sub/app', None)" || return 1
  git remote add origin git@github.com:Acme/widget.git
  check "a repo's origin end to end" "$(rpt --dry-run --no-outside)" '"repo": "Acme/widget",
      "url": "https://github.com/Acme/widget"'
}

t_report_dry_run() {
  rpt_setup rptdry; rpt_job 001-a; python3 -c "print('x' * 200)" > factory/jobs/001-a/long.md
  local out; out=$(rpt --dry-run --no-outside); local rc=$?
  check "exit 0, the payload, long files cut" "[$rc] $out" "…(201 chars)" &&
  check "nothing sent" "[$(test -e "$H/hub.log" && echo sent)]" "[]" &&
  check "no state written" "[$(test -e "$H/.cache/factory/report-state.json" && echo state)]" "[]" &&
  check "a real push still full afterwards" "$(rpt >/dev/null; hub 'b[0]["full"]')" "True"
}

t_report_outside() {
  rpt_setup rptout true; rpt_job 001-a
  rpt >/dev/null; rpt >/dev/null
  check "outside usage goes along once, then only when it changed" "$(hub '[("outside" in x, x.get("outside", {}).get("status")) for x in b]')" "[(True, 'ready'), (False, None)]"
}

t_report_install_service() {
  new_repo rptsvc; commit_all; H="$TMP_ROOT/rptsvc/home"; mkdir -p "$H"
  local out; out=$(rpt --install-service); local u="$H/.config/systemd/user/factory-report.service"
  check "prints the commands" "$out" "systemctl --user daemon-reload && systemctl --user enable --now factory-report" &&
  check "unit" "$(cat "$u")" "ExecStart=$PWD/factory/bin/report --watch" &&
  check "restarts" "$(cat "$u")" "Restart=always" &&
  check "restart delay" "$(cat "$u")" "RestartSec=10"
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
