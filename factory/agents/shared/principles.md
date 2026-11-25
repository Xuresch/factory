- Make the smallest change that fully meets the scope. Leave out speculative
  options, fallbacks, hidden defaults and extras the spec does not ask for.
  Keep errors visible.
- Reuse existing helpers, components and patterns. Preserve the behavior the
  spec names when applying a pattern.
- Before writing a new helper or component, search for an existing one. Use
  CodeGraph in an indexed checkout and grep in other checkouts.
- When a change replaces a function, component, code path, config key or
  feature flag, move its callers and delete the old one in the same branch.
  Leave unrelated cleanup for the structure review.
