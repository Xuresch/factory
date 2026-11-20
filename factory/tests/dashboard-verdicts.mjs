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
const drawer = html.match(/\/\/ ---- Drawer -+[^\n]*\n([\s\S]*?)\nfunction tokens\(/)[1]
const markdown = html.match(/\/\/ ---- Markdown [^\n]*\n([\s\S]*?)\/\/ ---- Board: what needs you/)[1]

const job = JSON.parse(readFileSync(join(fixtures, 'job.json'), 'utf8'))
const expected = JSON.parse(readFileSync(join(fixtures, 'expected.json'), 'utf8')).verdicts
const prefix = `jobs/${job.id}/`

async function fakeFetch(url) {
  const rel = url.startsWith(prefix) ? url.slice(prefix.length) : null
  const path = rel && join(fixtures, rel)
  if (!path) return new Response(null, { status: 404 })
  if (existsSync(path)) return new Response(readFileSync(path))
  const encoded = path + '.hex'
  if (existsSync(encoded)) return new Response(Buffer.from(readFileSync(encoded, 'utf8').replace(/\s/g, ''), 'hex'))
  return new Response(null, { status: 404 })
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

async function checkDrawer(hub) {
  const jobFiles = ['round-1/checks.md', 'round-3/review-code.md']
  const elements = {}
  const drawerJob = {
    ...job,
    stage: 'merged',
    files: jobFiles,
    rounds: [
      { round: 1, gate: 'PASS' },
      { round: 3, reviews: { code: 'invalid' } },
    ],
  }
  const make = new Function('fetch', 'hub', 'job', '$', 'DOMParser', block[1] + drawer + markdown + [
    'const jobs = [job], openJobId = job.id',
    'let openPath, openText',
    'const stub = () => "", money = stub, elapsed = stub, splitBar = stub, partsOf = stub, links = stub',
    'const repoChip = stub, ref = stub, isLocal = stub, costTable = stub, apiJobs = stub',
    'const fetchJSON = async () => job, esc = (s) => s',
    'return async (path) => { openPath = path; await refreshDrawer() }',
  ].join('\n'))
  const fetch = (url, ...args) => url === prefix
    ? Promise.resolve(new Response(jobFiles.join('\n')))
    : fakeFetch(url, ...args)
  const domParser = class {
    parseFromString(text) {
      return { querySelectorAll: () => text.split('\n').map((path) => ({ getAttribute: () => path })) }
    }
  }
  const open = make(fetch, hub, drawerJob, (id) => elements[id] ??= {}, domParser)
  for (const path of [undefined, 'round-3/review-code.md']) {
    await open(path)
    const badge = (file) => elements['d-files'].innerHTML.split('data-file="' + file + '"')[1]
      .match(/<span class="v ([^"]*)"/)[1]
    const context = (hub ? 'hub' : 'standalone') + (path ? ' open' : ' closed')
    check(context + ' wrong-prefix review badge', badge('round-3/review-code.md'), '')
    check(context + ' passing gate badge', badge('round-1/checks.md'), 'good')
    if (path) check(context + ' wrong-prefix review header', elements['d-doc'].innerHTML.includes('class="verdict good"'), false)
  }
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

await checkDrawer(null)
await checkDrawer({})

console.log(failed ? `${failed} failed` : `ok: ${Object.keys(expected).length} artifacts, ${rounds.length} rounds and 10 drawer assertions across both modes`)
process.exit(failed ? 1 : 0)
