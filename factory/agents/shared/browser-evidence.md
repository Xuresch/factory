When you can't look at a page (`agent-browser` missing, no way past sign-in,
the dev server won't start), don't skip it silently: write a `## Notes` line
`Not seen in a browser: <page> — <reason>`.

The builder leaves a screenshot set of every changed page in
`round-<N>/screenshots/`, listed under `## Screenshots` in build.md. Open
them, and cite a file by name in a finding about what it shows. Where you
couldn't look yourself, review the screenshots instead and write
`Seen only in the builder's screenshots: <page>` under `## Notes`; a changed
page with neither your look nor a screenshot keeps its `Not seen in a
browser` line.
