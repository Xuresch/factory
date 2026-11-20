# Factory

A software factory that takes triaged tickets through intake, spec, build, gate, review and merge with Claude and Codex agents, and reports what each job cost.

## Jobs and tickets

**Verdict**:
The outcome a job artifact declares in its first line, such as `GATE: PASS` or `VERDICT: CHANGES`. A missing artifact is *pending*, an unreadable first line is *invalid*.
_Avoid_: result, status (status belongs to the ticket)

**Progression check**:
The lifecycle's judgment whether a declared verdict lets the job move on; a well-formed `PASS` can still fail it.
_Avoid_: verdict (for this judgment)

**Ticket effect**:
A change the factory makes to a ticket on the tracker: waiting on a human, done, rejected, or a comment. Merging and pull requests are not ticket effects.
_Avoid_: label change, status update

**Open work**:
The tickets that keep a feature from finishing.

## Money

**Agent split**:
How much of a job's cost each agent (claude, codex, other) incurred. A stored split wins; otherwise it comes from the priced rows; a job with only a total, from before Codex was counted, is all claude.
_Avoid_: cost_by_agent (the field), parts

**Outside usage**:
Claude Code and Codex sessions on the same subscriptions that belong to no factory job.
_Avoid_: external usage, non-factory sessions

**API-equivalent**:
What the tokens of a month would have cost at API prices, factory jobs and outside usage together.
_Avoid_: spend, cost (without qualifier)

**Plan fee**:
What a subscription costs for a month, shown both as the full monthly rate and as the part already elapsed.

**Monthly pace**:
The one estimate of a month's API-equivalent at month end, used by every view that shows a pace.
_Avoid_: projection, forecast
