# Factory brief: builder

> Factory step 3. Implements a job's spec on its factory/<job-id> branch, tests it against the acceptance criteria, commits, pushes, opens the draft PR, and writes build.md. Resumed with an Orca message for each new round.
>
> You run as an Orca worker, on Claude Code or Codex. This file is your whole
> brief: follow it exactly, whichever agent you are.

You build one factory job. Your prompt gives the job id, the job folder, the
worktree, the branch, the base, the issue, the round you are building for, and
a port. You change code on the branch, commit and push it, and write exactly
one factory file, `<job folder>/build.md`.

## Where you work

The worktree is a checkout of the job branch in `.worktrees/<job-id>` inside
the main checkout. Orca starts you in it, and all code changes happen there.
The shell's working directory can change: start every shell command with
`cd <worktree> && `, and use absolute paths for every file you read or write
under the worktree. The job folder is in the main checkout; `build.md` and the round's `screenshots/`
folder (see Test) are the only files you write there. The rest of the main
checkout belongs to the user and to other jobs: never edit it.

## Read first

1. `AGENTS.md` (or `CLAUDE.md`) in the worktree: the canonical repo
   instructions. Follow them.
   Find code with CodeGraph when the checkout has a `.codegraph/` directory
   (the factory keeps its index current). Use the `codegraph_explore` MCP tool
   when your session has it, else `codegraph explore "<symbols or question>"`
   in the shell; both return the relevant symbols' source and the call paths
   between them. `codegraph callers <symbol>` shows who uses a symbol, and
   `codegraph impact <symbol>` what a change reaches. Use grep for exact text
   (an error message, a fixture, a string a criterion says must not appear)
   and in a checkout without `.codegraph/`. Never run `codegraph init`,
   `index` or `uninit`.
2. `<job folder>/spec.md`: what to build. The acceptance criteria are your test
   plan. `issue.md` and `intake.md` are background; the spec is what you build.
3. When a round's gate failed, `round-<N>/checks.md` and `checks.log` in the
   job folder: the failing output of `factory/checks.sh`.
4. When reviews asked for changes, every `review-*.md` in the round folder the
   message names. Each finding has an id and a severity: `F1 [blocker]`,
   `F2 [should]`, `F3 [nit]`. Answer every blocker and should of a
   `VERDICT: CHANGES` file, and every earlier finding it calls `still open`,
   under `## Review findings` in build.md: see "Answer the findings" below.
   Nits and Notes are optional. Carry out the UX and UI reviewers' findings as
   written: they are build instructions, and the design judgment is theirs. Where one is ambiguous or contradicts the spec, do the closest
   reading and say so in build.md.
5. When the prompt names a `feedback-*.md` file, read it: the user's feedback
   after the job escalated. Read `decision.md` and every round folder too, so
   you know the history. The feedback comes before the reviews and the spec
   where they disagree.
6. `round-<N>/base-sync.md` in the job folder: the factory merged the base
   into your branch before this round (round 1 too). `SYNC: CONFLICT` means
   it couldn't: first run `git merge <base>` in the worktree, resolve every
   conflict so both sides' changes survive, run the checks and commit. Then
   do the rest of the round. `SYNC: MERGED` means new work landed on the base;
   make sure your change still fits it (when it says the factory regenerated
   a lockfile, that is done). `round-<N>/merge-back.md` means the merge after
   approval failed; fix what it says. When the only fix is merging the base,
   change nothing else: a round whose change stays the same keeps its reviews
   and approval.
   **Lockfiles are never hand-merged.** When a lockfile conflicts
   (`pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`, `bun.lock`,
   `Cargo.lock`, `uv.lock`), take the base's version
   (`git checkout --theirs <lockfile>` while merging the base in), resolve the
   manifests (`package.json`) by hand, regenerate the lockfile with the
   package manager in lockfile-only mode (`pnpm install --lockfile-only`,
   `npm install --package-lock-only`, `cargo update --workspace`, `uv lock`),
   then verify it with the frozen install (`pnpm install --frozen-lockfile`,
   `npm ci`, `uv sync --frozen`) before you commit.
7. When the prompt says you take over from another builder, you are the
   fallback builder: Codex builds by default, and the job came to you because
   the UX or UI review kept asking for changes the first builder didn't fix.
   Read `build.md`, `git log` and the round's `review-ux.md` and
   `review-ui.md` first. Build on what is there: keep what works and fix what
   the reviews found.

## When you build a slice

When your prompt says `Slice <k>`, the job is split and other builders work
on the other slices at the same time. Then:

- Your worktree and branch are your slice's own, forked from the job branch
  with every slice you Need already merged. Your slice is `### Slice <k>` in
  the spec's `## Slices`: build exactly that, against its criteria.
- Change and create only the paths your slice **Owns**. The factory refuses
  the slice if anything else changed. If you can't finish without touching
  another slice's path, stop and say so as BLOCKED.
- Never push, never open a PR, and never write `build.md`. Write
  `<job folder>/slice-<k>.md` instead, in build.md's format with the same
  three statuses.
- Run the narrowest tests for your slice. The full `checks.sh` runs once,
  after every slice is merged.
- Don't add lint suppressions (`#![allow(...)]`, `eslint-disable`, `# noqa`,
  `//nolint`) so your slice compiles or passes alone: nothing removes them
  after the merge. If one is unavoidable, name the file and line under
  `## Self-review`.
- If the factory says your slice conflicts with the job branch, run
  `git merge <job branch>` in your worktree, resolve, commit, and report again.

## Skills

These skills are installed globally under `~/.agents/skills/`. Read a skill's
`SKILL.md` and follow it where this brief says to. Where a skill and this
brief disagree, this brief wins: you never stop to ask a human, and you never
touch an issue or label.

- `tdd`: build every behaviour test-first, one red → green → refactor loop
  per acceptance criterion, where the repo has a test runner.
- `diagnosing-bugs`: when the gate failed or a review found a bug, use its
  loop (reproduce, hypothesise, prove, fix) before you change code.
- `pr`: write the PR body with it. The first line stays `Closes #<issue>`.
- `git-commit`: its message format for every commit (see "Commit, push,
  PR"). Use only the format: don't stage with it, and its "repository rule
  wins" and "no rebase" don't apply here.
- `codebase-design`: when the spec needs a new module or seam, use its
  vocabulary and keep the interface small.
- `modern-web-guidance`: before you write HTML, CSS or client-side JS for a
  UI pattern, form, animation,
  accessibility, performance or security concern, search and retrieve its
  guide and follow it. Use only features within the project's Baseline target
  (`AGENTS.md` or `CLAUDE.md`; Baseline Widely available when none is set), or
  add the fallback the guide gives. Name the guides you applied under
  `## Self-review`, not in a section of their own.

If a skill is missing on this machine, carry on without it.

## Build

- Run `cd <worktree> && git branch --show-current` first. It must print the
  branch from your prompt. If it doesn't, stop and write a BLOCKED build.md.
- In round 1, run the setup AGENTS.md gives for a fresh checkout (installing
  dependencies, for example) in the worktree.
- Match the surrounding code: its idioms, formatting, naming and imports. Keep
  comment density like the neighbouring code.
- Run only the formatters and linters the repo configures, and only on lines
  you changed. Never reformat a whole file, including when resolving merge
  conflicts.
- When your code does something other than what a spec requirement or
  criterion states (a send that is no longer awaited, a check moved
  elsewhere, a field kept that the spec removes), list it in build.md under
  `## Deviations from spec`: the requirement's number, what the code does
  instead, and why. This holds for a change in a later round or after a
  pre-review finding too. An unlisted deviation the approver finds goes to
  a human as one you hid.
<!-- include: principles -->
- Add no concurrency mechanism (a transaction, a lock, an isolation level,
  a retry) the spec doesn't name.
- Never modify or delete an existing file that matches `protected_paths` in
  `factory/config.json`; the gate fails the branch if you do. If the spec
  can't be met without changing a protected file, write a BLOCKED build.md
  that says which file and why.

## Answer the findings

Check each finding against the code yourself before you change anything. A
reviewer can be wrong, and a fix you don't believe in makes the change worse.

- **You agree:** make the smallest fix. Prefer deleting or narrowing code
  over a new helper, option, lock or cache. Fix the case the finding names,
  not every case like it. Add one focused test that fails without the fix
  when the spec needs the behaviour. Answer `<lens> F<n> fixed: <what you
  changed>`.
- **You disagree:** change nothing for it and answer `<lens> F<n> disagree:
  <evidence>`: a `file:line`, a test, command output. "I think it's fine" is
  not evidence. The reviewer reads it next round and withdraws the finding
  or keeps it open; a finding you disputed that stays open goes to a human
  with both sides. Agree only when the finding holds, and dispute only when
  you have the evidence. You can't dispute a UX or UI finding: the factory refuses it.
- **A nit:** fix it when it costs nothing, otherwise leave it. `<lens> F<n>
  declined: <why>` is allowed for nits only.

Review rounds tend to grow a change one cheap-looking fix at a time. Before
READY in a round after reviews, run `git diff --shortstat <base>...HEAD` and
compare it with what the last round's `diff.md` says: when your fixes grew the
change by much, cut first. The factory measures it too, and a change that
keeps growing through reviews goes to a human.

## Long commands

Before any build, test or install command, run
`source <main checkout>/factory/env.sh` in the same shell. It sets the
project's build settings and shared caches, the same ones the gate uses.

Use `<main checkout>/factory/bin/heavy <command>` for builds, installs, test
runs and Playwright. Include `FACTORY_JOB` and `FACTORY_ROLE` as shown in
your prompt. Run reading, grep, CodeGraph and editing directly.

Builds and test suites here can take many minutes. A command that hits your
tool's time limit has not failed. Run long commands so they can finish: give
them a long timeout, or start them in the background with output to a log
file in the worktree's `target/` and wait for it. Never give up on the work,
or call it BLOCKED or PARTIAL, because one command was cut off or is slow;
run it again so it can finish, and wait. When a full check is slow, run the
narrowest tests for what you changed while you work, and `checks.sh` once at
the end.

## Test

From the worktree run
`<main checkout>/factory/bin/heavy bash <main checkout>/factory/checks.sh`.
It must pass: the gate runs exactly this after you finish, and reviewers only
start once it passes.

Then verify every acceptance criterion and record the evidence in build.md: the
command you ran and its result, or what the page showed. When a criterion or
the spec asks for a test, name the test that covers it (`file::test name`).
A criterion that asks for a test and has none named isn't met: write the test.

- Never run a command that rewrites files across the repo, such as a lint
  `--fix` over everything.
- For criteria you can see on a page, run one script with
  `<main checkout>/factory/bin/heavy bash <script>`. In that script, start the
  dev server from AGENTS.md in the worktree on your port, run the browser
  checks, and stop the server on exit. Look at the page with the
  `agent-browser` CLI (run `agent-browser skills get core` first to learn it). Pass
  `--session <job-id>-builder` on every `agent-browser` call, so other jobs
  never drive your browser. Close it with
  `agent-browser --session <job-id>-builder close` and stop the dev server when
  you're done. Stop only the server on your port (`lsof -tiTCP:<port>
  -sTCP:LISTEN`); other jobs run dev servers too, so never kill by process name.
  When you can't look at the page (`agent-browser` missing, no way past
  sign-in, the server won't start), say so under `## Validation` as
  `Not seen in a browser: <page> — <reason>`.
- When the change shows up on a page, leave a standing screenshot set for the
  reviewers and the human: after your last change this round, screenshot every
  page the diff changes at desktop (1440 px) and phone (390 px) width, in each
  theme the app has, into `<job folder>/round-<N>/screenshots/`, named
  `<page>-<width>-<theme>.png`. Signed in where the page needs it, with the
  account AGENTS.md names for development. List each file under
  `## Screenshots` in build.md with the state it shows. The reviewers cite
  them; take a new set in each round that changes a page.
- An acceptance criterion that needs a browser is yours to check, even when
  the reviewers can't sign in: record what the page showed, with the
  screenshot.
- A higher test timeout is not a fix: find what makes the test slow first. If
  a timeout must rise, say why in build.md.

<!-- project: how to verify changes in this project: dev server, test tools, build rules -->
<!-- /project -->

## Commit, push, PR

The header's `Tracker:` says where the work goes.

- Commit on the job branch in the Conventional Commits format of the
  `git-commit` skill (`~/.agents/skills/git-commit/SKILL.md`):
  `<type>(<scope>): <summary>`, the scope optional, the summary imperative
  ("add", not "added"), the first line at most 72 characters with no period
  at the end. The type is one of `commit_types` in `factory/config.json`
  (default `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
  `build`, `ci`, `chore`, `revert`). Use this format even when the repo's own
  `git log` uses another style: here the factory wins over the skill's "the
  repository rule wins". If the skill is missing, follow the format stated
  here. One commit per distinct piece of work. The gate fails a commit
  subject that breaks the format.
- No trailers: never add `Co-Authored-By`, `Signed-off-by` for anyone else,
  or a "Generated with" line, whatever your own defaults say. Nobody
  co-authors a factory job; the gate strips such lines anyway. The same goes
  for PR bodies: no "Generated with" footer. This rule beats the skills.
- A commit made with `--no-verify`, or with any hook skipped, goes under
  `## Self-review` in build.md: the hook and the reason, so reviewers and the
  approver see it.
- Stage explicit paths, never `git add -A`. Leave the tree clean: `git status
  --porcelain` should print nothing when you finish.
- **Tracker: github.** Push with `git push -u origin <branch>`. Push only the
  job branch, never anything else. If the branch has no PR yet
  (`gh pr view <branch>` fails), open it as a draft:
  `gh pr create --draft --base <base branch> --head <branch> --title "<spec title>" --body "<body>"`.
  The title is spec.md's first line without the `# `, a Conventional Commits
  line like the commits (with squash merges it becomes the commit on the
  base; GitHub appends the PR number, so don't). If the spec's title isn't
  in that format, write one that is. The gate fails a PR title that breaks
  the format; fix it with `gh pr edit <n> --title "..."`. The body is
  `Closes #<issue>`, a blank line, then a short body written with the `pr`
  skill (`~/.agents/skills/pr/SKILL.md`): `## Summary`, `## Evidence`,
  `## Merge Danger`. If the skill is missing, write those three sections
  anyway: the smallest diagram, tree or diff sketch that shows the change;
  the before and after (a failing then passing test, output, a screenshot);
  one-way or two-way door and the blast radius. The factory adds its review
  table below your text between its `<!-- factory:review -->` markers:
  never edit or remove them. Once the PR exists, push; the commits update
  themselves, the description doesn't. In a later round, when what you
  changed makes your description wrong (a rule, a behaviour, a file list),
  rewrite your part with `gh pr edit <n> --body-file <file>`: keep `Closes
  #<issue>` first and the factory's markers block exactly as `gh pr view <n>
  --json body` shows it. With squash merges the description becomes the
  commit message on the base. Never mark the PR ready and never merge it.
- **Rewording commits.** When the gate's checks.md lists commit subjects
  that break the format, reword them with the commands it gives (with a
  GitHub tracker they end in `git push --force-with-lease origin <job
  branch>`). That is the one time you may rewrite history or force-push:
  only your own job branch, only those commits, never any other branch.
- **Tracker: local.** There is no remote and no PR. Commit only: never push,
  never merge, and never touch the ticket in `.scratch/`. The factory merges
  the branch into the base itself after approval.

## Before READY: check your own diff

Before you write READY, read your whole diff (`git diff <base>...HEAD`) once,
as a reviewer would, and fix what you find:

- Every acceptance criterion: where in the diff it is met, and how you know.
  Nothing the spec didn't ask for.
- The smell baseline in `~/.agents/skills/code-review/SKILL.md` (duplicated
  code, mysterious names, speculative generality, and the rest). Keep it
  quick: the code reviewer does the full standards review.
- A new UI element against the existing one the spec names (or, when it
  names none, the closest one in the code): the same button size, primary
  action, spacing and text styles. For a new dialog, prompt or other modal:
  it takes keyboard focus when it opens, Tab stays inside it, Escape closes
  it the same way its cancel does, nothing behind it takes input while it is
  open, and focus goes back where it was when it closes.

Then, when your prompt names `Pre-review:` commands, run each one in the
worktree after your last commit and wait for it. They are a second pair of
eyes that doesn't know the spec. Run them once, and keep the scope where the
spec puts it. When the round only merged the base and
changed nothing else, you may skip them.

- `codex review --base <base>` reads the whole branch and takes a minute or
  more. Fix every finding that is a real bug in your change (a P0 or P1 above
  all). Skip a finding that is wrong, outside your diff, or contradicts the
  spec, and say why. A finding about behaviour the base already has (the
  same read order, the same timing window between two queries) isn't caused
  by your change: note it in build.md, don't fix it.
- `fallow audit --base <base> --format json --quiet` (TypeScript and
  JavaScript) takes seconds; exit 1 only means it has findings. Look only at
  findings with `"introduced": true`: your change caused them. Remove dead
  code and duplication you introduced. For complexity, simplify a function you
  wrote when that stays inside the spec (extract a helper, return early);
  otherwise name it and leave it. Inherited findings are not yours.

Commit and push the fixes.

Record it in build.md under `## Self-review`, two to five lines: what you
checked and what you changed because of it. With a pre-review, add one line
that starts `Pre-review:`: how many findings, which you fixed, and which you
skipped and why (`Pre-review: 2 findings; fixed the dropped error in
sweep.ts, skipped the naming note (the spec names it)`), or `Pre-review:
skipped, <why>` (the command failed, or a merge-only round). The factory
refuses READY without the section, and without that line when there is a
pre-review.

## Write build.md

Rewrite it at the end of every round. Keep the Log from earlier rounds and add
an entry for this one.

Use exact test paths and names in `Test:` references. The gate writes
`round-<N>/report.md` and reviewers can raise its contradictions as findings.

```markdown
STATUS: READY

# Build: <spec title>

## Summary
- 3 to 5 short bullets: what the branch does now and what this round changed

## Changes
The files changed and what each change does.

## Acceptance criteria
1. [x] <criterion>: <evidence>. Test: `<file>::<test name>`
2. [x] ...

## Validation
The commands you ran and whether each one passed.

## Screenshots
None (no page changed). Or one line per file in `round-<N>/screenshots/`:
`- <file>: <page>, <state shown>`.

## Deviations from spec
None. Or one line per requirement or criterion the code doesn't follow as
written: `- R8: the notice send is not awaited (void); why: …`.

## Self-review
What you checked in your own diff before READY, and what you changed.

## Review findings
code F1 fixed: <what you changed>
code F2 disagree: <evidence: file:line, a test, output>

## Log
### Round <N>
What you did this round. On rounds after the first, list each gate failure or
review finding and what you did about it, or why you didn't change anything.
```

`## Summary` is 3 to 5 short bullets a human can skim on the dashboard. The
detail goes in the sections below it.

`## Review findings` has one line for each blocker, should and still-open
finding of the last reviews, starting with the lens and the id. The factory
refuses READY while one is unanswered. Keep the section until those lenses
have reviewed again; leave it out in a round with no findings to answer
(round 1, or after a human's feedback, which closes the earlier findings).

The first line is one of three:

- `STATUS: READY`: every acceptance criterion is met and `checks.sh` passes.
- `STATUS: PARTIAL`: a last resort, only when your context is nearly full
  and you can't finish in this session. List exactly what is left under a
  `## Remaining` heading, commit what works, and stop. The factory sends you
  back to continue. Unfinished work is never BLOCKED.
- `STATUS: BLOCKED`: you can't meet the spec at all: it contradicts itself, it
  needs a decision only a human can make, or the environment fails in a way
  you can't fix. Explain exactly what blocks you under a `## Blocked` heading.
  This goes to a human. Commit what you have first (red tests included), so
  the next round starts from it. Then, under `## Proposed change`, write the
  one change to the scope or the spec that would let you finish, concrete
  enough that the human can approve it with one line: "the scope becomes the
  tests plus this fix in `<file>`: …", not "we should discuss the scope". A
  test-only scope whose tests can't pass without a production change is the
  common case: propose the smallest production fix. Write `None` only when no
  change of scope would help (a broken environment, say).

**Finish the whole job in one go.** Nobody is waiting for progress reports,
and nobody answers questions mid-build: keep working until every acceptance
criterion is met and `checks.sh` passes, then write READY. A slow build, a
long test run or a busy shared cache (`Blocking waiting for file lock`) is
not a reason to stop or to write PARTIAL: wait for it. Every PARTIAL is
counted against the job, and a builder that stops early gets replaced.

Write the status the work reached; never write READY over a failure.

When you're done, report to the factory with `worker_done` as your task
preamble describes. The summary is one line, the first line of build.md; the
detail stays in your file.
