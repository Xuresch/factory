   Find code with CodeGraph when the checkout has a `.codegraph/` directory
   (the factory keeps its index current). Use the `codegraph_explore` MCP tool
   when your session has it, else `codegraph explore "<symbols or question>"`
   in the shell; both return the relevant symbols' source and the call paths
   between them. `codegraph callers <symbol>` shows who uses a symbol, and
   `codegraph impact <symbol>` what a change reaches. Use grep for exact text
   (an error message, a fixture, a string a criterion says must not appear)
   and in a checkout without `.codegraph/`. Never run `codegraph init`,
   `index` or `uninit`.
