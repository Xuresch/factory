Run the browser session as one script,
`<main checkout>/factory/bin/heavy bash <script>`. In it, start the dev server
from AGENTS.md in the worktree on your port, run the browser checks, and stop
the server on exit.

Drive the page with the `agent-browser` CLI (run `agent-browser skills get
core` first). Pass `--session <job-id>-<lens>` (`ui` or `ux`) on every
`agent-browser` call, so other jobs' reviewers never drive your browser.
Don't sign in or submit forms: the dev server may talk to real services. When
you're done, run `agent-browser --session <job-id>-<lens> close` and stop the
dev server you started, by the PID listening on your port
(`lsof -tiTCP:<port> -sTCP:LISTEN`). Other jobs run dev servers too, so never
kill by process name.
