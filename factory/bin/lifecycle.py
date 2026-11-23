"""Decide a job's next transition from parsed reports and observed facts."""

from dataclasses import dataclass, field

from jobfiles import PENDING

TERMINAL = {"merged", "rejected"}
WAITING = {"needs-info", "needs-human", "paused"}
REJECTABLE = {"spec", "build", "gate", "review", "approve"}
REWINDABLE = REJECTABLE | {"paused", "needs-human"}

TRANSITIONS = {
    "intake": {"needs-info", "rejected", "spec", "needs-human"},
    "needs-info": {"intake", "rejected"},
    "spec": {"build", "rejected", "needs-human"},
    "build": {"gate", "needs-human", "rejected"},
    "gate": {"review", "build", "needs-human", "rejected"},
    "review": {"approve", "build", "needs-human", "rejected"},
    "approve": {"merging", "needs-human", "rejected"},
    "merging": {"needs-human", "build"},
    "needs-human": {"build", "rejected", "merging"},
    "paused": {"rejected"},
}


@dataclass(frozen=True)
class Facts:
    report: str | None = None
    problem: str | None = None
    protected: tuple = ()
    gate: dict | None = None
    head: str | None = None
    dirty: bool = False
    builder_answers: dict | None = None
    reviews: dict = field(default_factory=dict)
    review_problems: dict = field(default_factory=dict)
    disputes: tuple = ()
    continues_left: bool = False
    replied: bool = False
    rejection: bool = False
    approval: bool = False
    feedback: bool = False
    merged: bool = False
    merge_outcome: str | None = None
    merge_reason: str | None = None


@dataclass(frozen=True)
class Effect:
    name: str
    args: tuple = ()


@dataclass(frozen=True)
class Decision:
    action: str
    reason: str
    stage: str | None = None
    effects: tuple[Effect, ...] = ()


def rounds_left(job):
    return max(0, job["round_limit"] - job["round"])


def _round_reason(job):
    return f'round {job["round"]} of {job["round_limit"]}'


def _transition(stage, reason, *effects):
    if stage == "needs-human":
        effects += (Effect("request_human"),)
    if stage in TERMINAL:
        effects += (Effect("cleanup"),)
    return Decision("advance", reason, stage, effects + (Effect("finish"),))


def _rewind(job, target, max_rounds):
    if target not in {"intake", "spec", "build"}:
        return Decision("refuse", "rewind to intake, spec or build")
    if job["stage"] not in REWINDABLE:
        return Decision("refuse", f'{job["id"]} is in {job["stage"]}; '
                        f'only {", ".join(sorted(REWINDABLE))} jobs can be rewound')
    allowance = max(job["round_limit"], job["round"] + max_rounds)
    effects = (Effect("reset_after_feedback", (allowance,)),)
    if target == "build":
        effects += (Effect("next_round"), Effect("sync_with_base"))
    return Decision("rewind", "the operator requested a rewind", target, effects)


def _gate(job, facts):
    gate = facts.gate or {}
    verdict = gate.get("verdict", PENDING)
    if verdict == PENDING:
        return Decision("rerun-gate", f'run the gate first: factory/bin/gate {job["id"]}')
    if verdict not in {"PASS", "FAIL"}:
        return Decision("rerun-gate", "checks.md's first line isn't `GATE: PASS` or `GATE: FAIL`; run the gate again")
    if gate.get("commit") != facts.head or facts.head is None:
        return Decision("rerun-gate", "checks.md was written for another commit; run the gate again")
    if verdict == "PASS":
        return _transition("review", "the gate passed", Effect("open_review", (facts.head,)))
    if rounds_left(job):
        return _transition("build", _round_reason(job), Effect("next_round"))
    reason = (f'The gate failed in round {job["round"]}, the last allowed round. '
              f'See round-{job["round"]}/checks.md.')
    return _transition("needs-human", _round_reason(job), Effect("escalate", (reason,)))


def _review(job, facts):
    missing = [lens for lens, verdict in facts.reviews.items() if verdict == PENDING]
    if missing:
        return Decision("refuse", f'round {job["round"]} is missing reviews from: {", ".join(missing)}')
    if facts.review_problems:
        lens, why = next(iter(facts.review_problems.items()))
        return Decision("refuse", f"review-{lens}.md doesn't count: {why}. Send the reviewer-{lens} worker this message.")
    invalid = [lens for lens, verdict in facts.reviews.items() if verdict not in {"PASS", "CHANGES"}]
    if invalid:
        return Decision("refuse", f'invalid Verdicts from: {", ".join(invalid)}')
    if facts.dirty:
        return Decision("refuse", "the worktree changed during review; a reviewer edited files")
    if facts.head != job.get("review_head"):
        return Decision("refuse", "HEAD moved during review; a reviewer committed")
    changes = tuple(lens for lens, verdict in facts.reviews.items() if verdict == "CHANGES")
    record = Effect("record_review_verdicts", (facts.reviews,))
    pr = Effect("update_pr_review")
    if not changes:
        return _transition("approve", "every review passed", record, Effect("open_approval"), pr)
    if facts.disputes:
        keys = ", ".join(dispute["key"] for dispute in facts.disputes)
        return _transition("needs-human", f"{keys} stayed disputed", record,
                           Effect("escalate_disputes", (facts.disputes,)), pr)
    if rounds_left(job):
        return _transition("build", _round_reason(job), record, Effect("maybe_fall_back", (changes,)),
                           Effect("remember_reviewed"), Effect("next_round"), pr)
    reason = (f'Review rounds exhausted. Outstanding CHANGES in round-{job["round"]}/ '
              f'from: {", ".join(changes)}.')
    return _transition("needs-human", _round_reason(job), record, Effect("escalate", (reason,)), pr)


def _progression(job, facts, target, max_rounds):
    stage, report = job["stage"], facts.report
    if target == "merged":
        if facts.merged:
            return _transition("merged", "the job is merged", Effect("close_merged"))
        return Decision("refuse", facts.problem or "the job isn't merged")
    if target == "rejected" and (stage != "intake" or facts.rejection):
        if facts.rejection:
            return _transition("rejected", "the operator rejected the job", Effect("reject"))
        return Decision("refuse", "use `job reject` to reject a job")
    if facts.problem:
        return Decision("refuse", facts.problem)

    if stage == "intake":
        if report == "ACCEPT":
            if not job.get("agents"):
                return Decision("route", "route the job first: factory/bin/route " + job["id"])
            return _transition("spec", "intake accepted", Effect("prepare_worktree"), Effect("post_intake", ("spec",)),
                               Effect("maybe_skip_spec"))
        if report == "NEEDS-INFO":
            return _transition("needs-info", "intake needs information", Effect("post_intake", ("needs-info",)),
                               Effect("wait_for_info"))
        if report == "REJECT":
            return _transition("rejected", "intake rejected", Effect("post_intake", ("rejected",)), Effect("return_ticket"))
        if report == "PROTECTED":
            return _transition("needs-human", "intake listed only protected files",
                               Effect("stop_protected_intake", (facts.protected,)))
        return Decision("send", "intake.md needs a first line DECISION: ACCEPT, NEEDS-INFO, REJECT or PROTECTED. "
                                "Fix it and report again.")
    if stage == "needs-info":
        if target == "intake" or facts.replied:
            return _transition("intake", "intake is ready to run again", Effect("reopen_intake"))
        return Decision("wait", f'author: intake asked on {job["issue"]}; no answer yet')
    if stage == "spec":
        if facts.protected:
            return _transition("needs-human", f'every path spec.md names is protected ({", ".join(facts.protected)})',
                               Effect("stop_protected", (facts.protected, None)))
        return _transition("build", "spec.md names paths outside protected_paths (or none)",
                           Effect("set_slices"), Effect("next_round"))
    if stage == "build":
        if report == "STATUS: READY":
            if facts.dirty:
                return Decision("refuse", "the worktree has uncommitted changes")
            return _transition("gate", "the build is ready", Effect("prepare_build_gate", (facts.builder_answers,)))
        if report == "STATUS: PARTIAL" and facts.continues_left:
            return Decision("continue", "the builder has continues left in this round")
        if report in {"STATUS: BLOCKED", "STATUS: PARTIAL"}:
            why = "the builder is blocked" if report.endswith("BLOCKED") else "the builder ran out of continues"
            return _transition("needs-human", why, Effect("escalate_build", (report,)))
        return Decision("send", f"build.md starts with {report}; its first line must be STATUS: READY, PARTIAL or BLOCKED.")
    if stage == "gate":
        return _gate(job, facts)
    if stage == "review":
        return _review(job, facts)
    if stage == "approve":
        if report not in {"APPROVE", "ESCALATE"}:
            return Decision("send", "decision.md must start with APPROVE or ESCALATE. Fix it and report again.")
        if facts.dirty or facts.head != job.get("review_head"):
            return Decision("refuse", "the branch changed after review; the approver only writes decision.md")
        if report == "APPROVE":
            return _transition("merging", "the approver approved", Effect("record_approval", ("approver",)))
        return _transition("needs-human", "the approver escalated")
    if stage == "merging":
        reason = facts.merge_reason or "only `job merge` can apply a merge outcome"
        if facts.merge_outcome == "recoverable" and rounds_left(job):
            return _transition("build", reason, Effect("remember_reviewed"), Effect("next_round"),
                               Effect("record_merge_failure", (reason,)))
        if facts.merge_outcome in {"recoverable", "escalate"}:
            return _transition("needs-human", reason, Effect("escalate", (reason,)))
        return Decision("refuse", reason)
    if stage == "needs-human":
        if target == "merging":
            if facts.approval:
                return _transition("merging", "the operator approved", Effect("record_approval", ("human",)),
                                   Effect("resume_ticket"))
            return Decision("refuse", "use `job approve` to merge an escalated job")
        if facts.feedback:
            return _transition("build", "the operator gave feedback",
                               Effect("reset_after_feedback", (job["round"] + max_rounds,)),
                               Effect("next_round"), Effect("resume_ticket"))
        return Decision("refuse", "use `job feedback` to send a job back to the builder")
    return Decision("refuse", f"no transition available from {stage}")


def legal_target(old, target):
    # A human can merge the PR while a job is in any unfinished stage.
    return target in TRANSITIONS.get(old, ()) or (target == "merged" and old not in TERMINAL)


def decide(job, facts=None, *, target=None, intent="advance", max_rounds=0):
    """Use the same decision for advice and application. A target is a check,
    except for explicit operator actions such as rejection and rewind."""
    if intent == "rewind":
        return _rewind(job, target, max_rounds)
    old = job["stage"]
    if target is not None and not legal_target(old, target):
        return Decision("refuse", f'{job["id"]}: {old} → {target} is not a legal transition')
    facts = facts or Facts()
    if facts.merge_outcome is not None and old != "merging":
        return Decision("refuse", f'{job["id"]} is in {old}, not merging')
    decision = _progression(job, facts, target, max_rounds)
    if target is None or decision.stage == target:
        return decision
    reason = decision.reason
    if old == "spec" and decision.stage == "build":
        reason += ", so advance it to build"
    elif decision.stage:
        reason += f": go to {decision.stage}"
    return Decision("refuse", reason)
