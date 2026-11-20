// The standalone dashboard's Verdict read against the shared job-folder fixtures.
//
// Usage: node factory/tests/dashboard-verdicts.mjs        (factory/tests/run.sh runs it)
//
// Runs the "verdicts" block of factory/dashboard.html with a fetch that serves
// factory/tests/fixtures/verdicts/ as jobs/900-verdicts/, and checks every
// artifact against expected.json, the file Python and the hub are tested against.
import { readFileSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const fixtures = join(here, 'fixtures', 'verdicts')
const html = readFileSync(join(here, '..', 'dashboard.html'), 'utf8')
const block = html.match(/\/\/ ---- verdicts: begin[^\n]*\n([\s\S]*?)\/\/ ---- verdicts: end/)
if (!block) throw new Error('dashboard.html has no "verdicts: begin" ... "verdicts: end" block')

const job = JSON.parse(readFileSync(join(fixtures, 'job.json'), 'utf8'))
const expected = JSON.parse(readFileSync(join(fixtures, 'expected.json'), 'utf8')).verdicts
const prefix = `jobs/${job.id}/`

async function fakeFetch(url) {
  const rel = url.startsWith(prefix) ? url.slice(prefix.length) : null
  const path = rel && join(fixtures, rel)
  if (!path || !existsSync(path)) return new Response('File not found', { status: 404 })
  return new Response(readFileSync(path))
}

function load(hub) {
  const make = new Function('fetch', 'hub', 'roundCache',
    block[1] + '\nreturn { fetchFirst, verdictOf, roundVerdicts }')
  return make(fakeFetch, hub, new Map())
}

let failed = 0
const check = (what, got, want) => {
  if (got !== want) { failed++; console.log(`FAIL ${what}: got ${got}, expected ${want}`) }
}

const standalone = load(null)
for (const [rel, want] of Object.entries(expected)) {
  const kind = /(^|\/)(merge-)?checks\.md$/.test(rel) ? 'checks' : 'review'
  check(rel, standalone.verdictOf(kind, await standalone.fetchFirst(prefix + rel)), want)
}

// The board's rounds, standalone (read from the files) and on the hub (read from the
// projection, which hub/src/project.rs tests against the same expected.json).
const rounds = Array.from({ length: job.round }, (_, i) => i + 1)
const projected = rounds.map((n) => ({
  round: n,
  gate: expected[`round-${n}/checks.md`] === 'pending' ? null : expected[`round-${n}/checks.md`],
  reviews: Object.fromEntries(Object.keys(job.agents.reviewers)
    .filter((l) => (expected[`round-${n}/review-${l}.md`] || 'pending') !== 'pending')
    .map((l) => [l, expected[`round-${n}/review-${l}.md`]])),
}))
const hub = load({})
for (const n of rounds) {
  for (const [mode, impl, j] of [['standalone', standalone, job], ['hub', hub, { ...job, rounds: projected }]]) {
    const v = await impl.roundVerdicts(j, n)
    check(`${mode} round ${n} gate`, v.gate, expected[`round-${n}/checks.md`])
    if (mode === 'hub' || v.gate === 'PASS') {
      for (const lens of Object.keys(job.agents.reviewers)) {
        check(`${mode} round ${n} ${lens}`, v.reviews[lens], expected[`round-${n}/review-${lens}.md`] || 'pending')
      }
    }
  }
}

console.log(failed ? `${failed} failed` : `ok: ${Object.keys(expected).length} artifacts, ${rounds.length} rounds in both modes`)
process.exit(failed ? 1 : 0)
