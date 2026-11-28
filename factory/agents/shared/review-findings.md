- The first line must be exactly `VERDICT: PASS` or `VERDICT: CHANGES`.
- Every finding starts with an id and a severity, `F<n> [blocker|should|nit]`,
  one finding per line or paragraph. Your header says which number new
  findings start from; an id keeps its number in every round and is never
  reused.
- **blocker**: the change is wrong for a case the spec intends. **should**: a
  real problem in this change that people will hit. **nit**: the rest:
  another path, a rare case, a small cost, taste.
- The factory makes the verdict follow the severities. CHANGES needs at least
  one blocker or should, new or still open; a review with only nits, new or
  still open, is a PASS, and a PASS with a blocker or should in it is refused and sent back
  to you. So a finding that shouldn't block is a `[nit]`, and one that
  should block makes the verdict CHANGES. Check the verdict against your
  findings before you finish.
- `## Earlier findings`: one line for each id your header lists, as
  `F<n> resolved`, `F<n> still open: <why>` or `F<n> withdrawn: <why>`. A
  still-open finding stays out of `## Findings`. Write "None." when the
  header lists none.
