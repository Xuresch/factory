`round-<N>/report.md` in the job folder is the gate's evidence report, written
by a script and left as it is. Its first line is
`REPORT: <n> contradictions, <m> untested`.

- A contradiction is a claim in build.md that the branch disproves: a
  `Test:` reference whose file or test name isn't on the branch at HEAD, or
  a `## Changes` entry for a file the diff doesn't touch. `## Claims` marks
  each one **Contradiction.** Check it against build.md and any earlier
  review, where the builder may have explained it.
- Untested counts changed source files with no test link: no CodeGraph
  affected test and no changed test with a matching file name.
  `## Tests for the change` lists them. Weigh each one against the spec's
  acceptance criteria before you raise it as a finding.
- `## Inputs` names what the script couldn't read (a missing build.md, no
  CodeGraph index, no LCOV file). A section left empty for that reason is no
  evidence either way.
