To confirm a finding with a build, test suite, Playwright or `checks.sh`, use
`<main checkout>/factory/bin/heavy <command>`, for example
`<main checkout>/factory/bin/heavy bash <main checkout>/factory/checks.sh`.
Set `FACTORY_JOB` and `FACTORY_ROLE` as the prompt shows. When the check
needs a dev server, wrap startup, the check and cleanup in one script under
`heavy`. Run reading, grep, CodeGraph and editing directly.
