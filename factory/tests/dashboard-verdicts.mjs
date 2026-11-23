// The standalone dashboard's Verdict read against the shared job-folder fixtures.
//
// Usage: node factory/tests/dashboard-verdicts.mjs        (factory/tests/run.sh runs it)
//
// Runs the job summary adapters and dashboard drawer with a fetch that serves
// factory/tests/fixtures/verdicts/ as jobs/900-verdicts/, and checks every
// artifact against expected.json, the file Python and the hub are tested against.
import { readFileSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import JobSummary from '../job-summary.js'

const here = dirname(fileURLToPath(import.meta.url))
const fixtures = join(here, 'fixtures', 'verdicts')
const html = readFileSync(join(here, '..', 'dashboard.html'), 'utf8')
const fetchBlock = html.match(/\/\/ ---- Text fetch [^\n]*\n([\s\S]*?)\/\/ ---- Board /)[1]
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

const textFetcher = new Function('fetch', fetchBlock + '\nreturn fetchText')
const fetchText = textFetcher(fakeFetch)

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
  const make = new Function('JobSummary', 'jobSource', 'job', '$', drawer + markdown + [
    'const jobs = [job], openJobId = job.id',
    'let openPath, openText',
    'const stub = () => "", money = stub, elapsed = stub, splitBar = stub, links = stub',
    'const repoChip = stub, ref = stub, isLocal = stub, costTable = stub, esc = (s) => s',
    'return async (path) => { openPath = path; await refreshDrawer() }',
  ].join('\n'))
  const fetchText = textFetcher(async (url) => {
    if (url === prefix) return new Response('<a href="round-1/">R1</a><a href="round-3/">R3</a>')
    if (url === prefix + 'round-1/') return new Response('<a href="checks.md">checks</a>')
    if (url === prefix + 'round-3/') return new Response('<a href="review-code.md">review</a>')
    if (url === '/api/repos/o/r/jobs/' + job.id) return new Response(JSON.stringify(drawerJob))
    return fakeFetch(url)
  })
  const source = hub
    ? JobSummary.hubAdapter({ fetchText, repo: 'o/r' })
    : JobSummary.localAdapter({ fetchText })
  const summary = hub ? JobSummary.fromHub(drawerJob, { repo: 'o/r' }) : JobSummary.fromLocal(drawerJob)
  const open = make(JobSummary, () => source, summary, (id) => elements[id] ??= {})
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

for (const [rel, want] of Object.entries(expected)) {
  const kind = JobSummary.roundArtifactKind(rel)
  const line = await fetchText(prefix + rel, kind).then((text) => text.split('\n', 1)[0])
    .catch((err) => { if (err.status === 404) return null; throw err })
  check(rel, JobSummary.verdictOf(kind, line), want)
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
const hub = JobSummary.fromHub({ ...job, rounds: projected }, { repo: 'o/r' })
for (const n of rounds) {
  const source = JobSummary.localAdapter({ fetchText: async (url, kind) => {
    if (url === 'jobs/') return `<a href="${job.id}/">${job.id}</a>`
    if (url === prefix + 'job.json') return JSON.stringify({ ...job, stage: 'review', round: n })
    return fetchText(url, kind)
  } })
  const [local] = await source.list()
  for (const [mode, summary] of [['standalone', local], ['hub', hub]]) {
    const v = JobSummary.roundOf(summary, n)
    check(`${mode} round ${n} gate`, v.gate, expected[`round-${n}/checks.md`])
    if (mode === 'hub' || v.gate === 'PASS') {
      for (const lens of Object.keys(job.agents.reviewers)) {
        check(`${mode} round ${n} ${lens}`, v.reviews[lens], expected[`round-${n}/review-${lens}.md`] || 'pending')
      }
    }
  }
}

await checkDrawer(false)
await checkDrawer(true)

console.log(failed ? `${failed} failed` : `ok: ${Object.keys(expected).length} artifacts, ${rounds.length} rounds and 10 drawer assertions across both modes`)
process.exit(failed ? 1 : 0)
