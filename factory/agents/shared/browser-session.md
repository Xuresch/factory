Run the browser session as one script,
`<main checkout>/factory/bin/heavy --pool browser bash <script>`. In it, start
the dev server from AGENTS.md in the worktree on your port, run the browser
checks, and stop the server on exit. Inside the script, run builds and tests
with plain `<main checkout>/factory/bin/heavy <command>`. Take the browser slot
first: heavy refuses one inside a heavy slot.

Drive the page with the `agent-browser` CLI (run `agent-browser skills get
core` first). Pass `--session <job-id>-<lens>` (`ui` or `ux`) on every
`agent-browser` call, so other jobs' reviewers never drive your browser.
Sign in or submit forms only when the project block below allows it, with the
account and server it names: the dev server may talk to real services.

<!-- project: how reviewers may sign in and submit forms against a local server, if at all -->
<!-- /project -->

When you're done, run `agent-browser --session <job-id>-<lens> close` and stop the
dev server you started, by the PID listening on your port
(`lsof -tiTCP:<port> -sTCP:LISTEN`). Other jobs run dev servers too, so never
kill by process name.
