// Tests for factory/job-summary.js and the dashboard's use of it.
// Run: node --test factory/tests/job_summary.test.js (factory/tests/run.sh job_summary runs it too).
// No network: the local tree and the hub API are served by a fake fetch, the dashboard runs in a vm
// with just enough DOM for its renderers.
const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const vm = require('node:vm')
const { spawnSync } = require('node:child_process')

const FACTORY = path.resolve(__dirname, '..')
const J = require(path.join(FACTORY, 'job-summary.js'))
const FIXTURES = JSON.parse(fs.readFileSync(path.join(__dirname, 'job_summary_fixtures.json'), 'utf8')).jobs
const near = (a, b, what = '') => assert.ok(Math.abs(a - b) < 1e-9, `${what} expected ${b}, got ${a}`)
const sameSplit = (got, want, what = '') => { for (const k of ['claude', 'codex', 'other']) near(got[k], want[k], `${what} ${k}`) }

// What the hub serves for a job.json (hub/src/project.rs + api.rs): derived columns, the recorded split
// as cost_split, the priced rows, the timing in seconds, the served id.
function hubJob(doc, { id = doc.id, repo = 'o/r', machine = 'm1' } = {}) {
  const rows = doc.cost_breakdown || []
  const rec = doc.cost_by_agent && typeof doc.cost_by_agent === 'object' ? doc.cost_by_agent : null
  const projected = FIXTURES.find((f) => f.doc.id === doc.id)?.expect ?? J.fromLocal(doc).split
  const secs = doc.started && doc.ended ? (Date.parse(doc.ended) - Date.parse(doc.started)) / 1000 : null
  const { cost_by_agent, ...rest_doc } = doc
  return { ...rest_doc, id, key: doc.id, repo, machine, href: '/r/' + repo + '/dashboard.html#job=' + id,
    cost_by_agent: projected, cost_split: rec,
    cost_breakdown: rows, duration_s: secs, wait_s: secs === null ? null : 0, work_s: secs, rounds: doc.rounds || [] }
}

// python -m http.server's directory index.
const listing = (names) => '<ul>' + names.map((n) => '<li><a href="' + encodeURIComponent(n).replace(/%2F/g, '/') + '">' + n + '</a></li>').join('') + '</ul>'

// A fetchText over a map of url -> body (a function body is called each time); missing urls are 404s.
function server(files, log = []) {
  return async (url) => {
    log.push(url)
    const body = files[url]
    if (body === undefined) throw new Error(url + ': HTTP 404')
    return typeof body === 'function' ? body() : body
  }
}

// The static tree factory/bin/dashboard serves for some job.json documents and their files.
function localTree(docs, extra = {}) {
  const files = { 'jobs/': listing([...docs.map((d) => d.id + '/'), '_features/']) }
  for (const d of docs) {
    const mine = Object.keys(extra).filter((k) => k.startsWith('jobs/' + d.id + '/')).map((k) => k.slice(('jobs/' + d.id + '/').length))
    const top = [...new Set(['job.json', ...mine.map((m) => (m.includes('/') ? m.split('/')[0] + '/' : m))])]
    files['jobs/' + d.id + '/'] = listing(top)
    for (const dir of top.filter((t) => t.endsWith('/'))) {
      files['jobs/' + d.id + '/' + dir] = listing(mine.filter((m) => m.startsWith(dir)).map((m) => m.slice(dir.length)))
    }
    files['jobs/' + d.id + '/job.json'] = JSON.stringify(d)
  }
  return { ...files, ...extra }
}

// ---- the Agent split -------------------------------------------------------

test('the same fixtures give the same Agent split through both adapters', async () => {
  const docs = FIXTURES.map((f) => f.doc)
  const local = await J.localAdapter({ fetchText: server(localTree(docs)) }).list()
  const one = await J.hubAdapter({ fetchText: server({ '/api/repos/o/r/jobs': JSON.stringify({ jobs: docs.map((d) => hubJob(d)) }) }), repo: 'o/r' }).list()
  const all = await J.hubAdapter({ fetchText: server({ '/api/all/jobs': JSON.stringify({ jobs: docs.map((d) => hubJob(d, { id: 'r~' + d.id })) }) }), repo: 'all' }).list()
  for (const f of FIXTURES) {
    for (const [mode, list] of [['local', local], ['hub repo', one], ['hub all', all]]) {
      const s = list.find((j) => j.key === f.doc.id || j.id === f.doc.id)
      assert.ok(s, mode + ' lists ' + f.doc.id)
      sameSplit(s.split, f.expect, mode + ' ' + f.doc.id)
      near(s.cost_usd, f.doc.cost_usd) // the recorded total stays
    }
  }
})

test('the rule: stored split, then priced rows, then a total-only job is claude', () => {
  sameSplit(J.agentSplit({ total: 12 }), { claude: 12, codex: 0, other: 0 })
  sameSplit(J.agentSplit({ total: 12, split: null, rows: [] }), { claude: 12, codex: 0, other: 0 })
  sameSplit(J.agentSplit({ total: 2, split: { claude: 0, codex: 0 }, rows: [{ agent: 'claude', cost_usd: 2 }] }), { claude: 0, codex: 0, other: 2 })
  sameSplit(J.agentSplit({ total: 2, split: {}, rows: [{ agent: 'mystery', cost_usd: 2 }] }), { claude: 0, codex: 0, other: 2 })
  sameSplit(J.agentSplit({ total: 1.004, split: { claude: 1 } }), { claude: 1, codex: 0, other: 0 })
  sameSplit(J.agentSplit({ total: 1.006, split: { claude: 1 } }), { claude: 1, codex: 0, other: 0.006 })
})

test('hub job summaries use the projected Agent split', () => {
  const doc = hubJob(FIXTURES[0].doc)
  const projected = { claude: 0, codex: 0, other: 5 }
  sameSplit(J.fromHub({ ...doc, cost_by_agent: projected }).split, projected)
})

test('an unassigned half cent counts as Other', () => {
  assert.equal(J.agentSplit({ total: 1.005, split: { claude: 1 } }).other, 0.005)
  assert.equal(J.agentSplit({ total: 0.305, split: { claude: 0.1, codex: 0.2 } }).other, 0.005)
  for (const [total, other] of [[1.004999, 0], [1.005, 0.005], [1.005001, 0.005001]]) {
    sameSplit(J.agentSplit({ total, split: { claude: 1 } }), { claude: 1, codex: 0, other })
    sameSplit(J.agentSplit({ total, rows: [{ agent: 'claude', cost_usd: 0.7 }, { agent: 'codex', cost_usd: 0.3 }] }),
      { claude: 0.7, codex: 0.3, other })
  }
})

const INSTALL = path.join(FACTORY, '..', 'INSTALL.md')
const installDocs = fs.existsSync(INSTALL) ? fs.readFileSync(INSTALL, 'utf8') : ''
test('the documented copy manifest installs a runnable job summary test', {
  skip: !installDocs.includes('https://raw.githubusercontent.com/Xuresch/factory/main'),
}, (t) => {
  const paths = installDocs.match(/## 1\. Copy\n[\s\S]*?\n```\n([\s\S]*?)\n```/)[1].split('\n')
  const project = fs.mkdtempSync(path.join(os.tmpdir(), 'job-summary-install-'))
  t.after(() => fs.rmSync(project, { recursive: true, force: true }))
  for (const file of paths) {
    const dest = path.join(project, file)
    fs.mkdirSync(path.dirname(dest), { recursive: true })
    fs.copyFileSync(path.join(FACTORY, '..', file), dest)
  }
  const env = { ...process.env }
  delete env.NODE_TEST_CONTEXT
  const result = spawnSync(process.execPath, ['--test', 'factory/tests/job_summary.test.js'],
    { cwd: project, encoding: 'utf8', env })
  assert.equal(result.status, 0, result.stdout + result.stderr)
})

// ---- static local serving -------------------------------------------------

test('local: round Verdicts of a job in flight, pending and invalid kept', async () => {
  const doc = { id: '020-live', title: 'live', stage: 'review', round: 2, started: '2026-11-18T10:00:00Z', cost_usd: 1,
    agents: { reviewers: { code: {}, ui: {} } } }
  const tree = localTree([doc], { 'jobs/020-live/round-2/checks.md': 'GATE: PASS\n', 'jobs/020-live/round-2/review-code.md': 'looks fine\n' })
  const [s] = await J.localAdapter({ fetchText: server(tree) }).list()
  assert.deepEqual(J.roundOf(s, 2), { gate: 'PASS', reviews: { code: 'invalid', ui: 'pending' } })
  assert.deepEqual(J.roundOf(s, 1), { gate: 'pending', reviews: { code: 'pending', ui: 'pending' } })
  assert.equal(s.repo, null)
  assert.equal(s.repoLabel, null)
})

test('local: the detail operation lists and reads the documents, a missing one fails', async () => {
  const doc = { id: '021-x', title: 'x', stage: 'merged', round: 1, started: '2026-11-18T10:00:00Z', ended: '2026-11-18T10:30:00Z', cost_usd: 1 }
  const tree = localTree([doc], { 'jobs/021-x/spec.md': '# Spec\n', 'jobs/021-x/round-1/checks.md': 'GATE: FAIL\nmore\n' })
  const src = J.localAdapter({ fetchText: server(tree) })
  const [s] = await src.list()
  const d = await src.detail(s)
  assert.deepEqual(d.files.sort(), ['round-1/checks.md', 'spec.md'])
  assert.equal(d.firstLine('round-1/checks.md'), 'GATE: FAIL')
  assert.equal(await src.read(s, 'spec.md'), '# Spec\n')
  await assert.rejects(src.read(s, 'gone.md'), /404/)
  assert.deepEqual(s.times, { total: 30 * 60000, wait: 0, work: 30 * 60000 })
})

// ---- the hub, one repo and all repos -----------------------------------------

test('hub: duplicate keys from two machines stay apart, repo labels follow the view', async () => {
  const doc = FIXTURES[0].doc
  const jobs = [hubJob(doc, { id: 'm1~' + doc.id, machine: 'm1' }), hubJob(doc, { id: 'm2~' + doc.id, machine: 'm2' })]
  const one = await J.hubAdapter({ fetchText: server({ '/api/repos/o/r/jobs': JSON.stringify({ jobs }) }), repo: 'o/r' }).list()
  assert.deepEqual(one.map((j) => j.id), ['m1~' + doc.id, 'm2~' + doc.id])
  assert.deepEqual(one.map((j) => [j.repo, j.repoLabel]), [['o/r', null], ['o/r', null]])
  const all = await J.hubAdapter({ fetchText: server({ '/api/all/jobs': JSON.stringify({ jobs }) }), repo: 'all' }).list()
  assert.deepEqual(all.map((j) => [j.repo, j.repoLabel]), [['o/r', 'o/r'], ['o/r', 'o/r']])
})

test('hub: the detail operation fetches the job and reads its documents from the tree', async () => {
  const doc = { ...FIXTURES[0].doc, rounds: [{ round: 1, gate: 'PASS', reviews: { code: 'CHANGES' } }] }
  const job = hubJob(doc, { id: 'm1~' + doc.id })
  const log = []
  const src = J.hubAdapter({ repo: 'o/r', fetchText: server({
    '/api/repos/o/r/jobs': JSON.stringify({ jobs: [job] }),
    ['/api/repos/o/r/jobs/' + encodeURIComponent(job.id)]: JSON.stringify({ ...job, files: ['spec.md', 'round-1/checks.md', 'round-1/review-code.md', 'job.json'] }),
    ['jobs/' + job.id + '/spec.md']: '# Spec\n',
  }, log) })
  const [s] = await src.list()
  const d = await src.detail(s)
  assert.deepEqual(d.files, ['spec.md', 'round-1/checks.md', 'round-1/review-code.md'])
  assert.equal(d.firstLine('round-1/checks.md'), 'GATE: PASS')
  assert.equal(d.firstLine('round-1/review-code.md'), 'VERDICT: CHANGES')
  sameSplit(d.job.split, FIXTURES[0].expect)
  assert.equal(await src.read(d.job, 'spec.md'), '# Spec\n')
  await assert.rejects(src.read(d.job, 'gone.md'), /404/)
})

// ---- the dashboard ---------------------------------------------------------------

// Runs factory/dashboard.html's scripts in a vm. files: url -> body for its fetches ('hub' decides the mode).
function dashboard(files) {
  const els = new Map()
  const clickListeners = []
  let pollTick
  const el = (id) => {
    if (!els.has(id)) {
      const attrs = {}
      els.set(id, { id, innerHTML: '', textContent: '', hidden: false, className: '', style: {}, dataset: {},
        parentElement: { scrollTop: 0 }, classList: { add() {}, remove() {} }, focus() {}, matches: () => false,
        setAttribute: (k, v) => { attrs[k] = v }, getAttribute: (k) => attrs[k] ?? null, removeAttribute: (k) => { delete attrs[k] },
        querySelector: () => el(id + ':child'), getBoundingClientRect: () => ({ left: 0, top: 0, width: 0 }) })
    }
    return els.get(id)
  }
  const fetchFake = async (url) => {
    const body = files[url]
    if (body === undefined) return { ok: false, status: 404, text: async () => 'not found', json: async () => null }
    const text = typeof body === 'function' ? await body() : body
    return new Response(text)
  }
  const document = { getElementById: el, activeElement: null, body: { classList: { add() {}, remove() {} } },
    documentElement: { classList: { add() {}, remove() {} }, clientWidth: 1200 }, head: { append() {} },
    createElement: () => ({}), addEventListener(type, listener) { if (type === 'click') clickListeners.push(listener) }, querySelector: () => null }
  const ctx = { document, fetch: fetchFake, location: { hash: '', search: '', pathname: '/dashboard.html', href: 'http://x/dashboard.html', port: '' },
    history: { replaceState() {}, state: null }, innerWidth: 1200, innerHeight: 800, addEventListener() {},
    setInterval: (callback) => { pollTick = callback; return 0 }, clearTimeout() {}, setTimeout: () => 0, console, URL, URLSearchParams, Date, Math, JSON, Promise, TextDecoder }
  ctx.self = ctx
  ctx.window = ctx
  vm.createContext(ctx)
  const html = fs.readFileSync(path.join(FACTORY, 'dashboard.html'), 'utf8')
  vm.runInContext(fs.readFileSync(path.join(FACTORY, 'job-summary.js'), 'utf8'), ctx)
  const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]).filter((s) => s.includes('POLL_MS'))
  vm.runInContext(scripts[0], ctx)
  const clickJob = (id) => Promise.all(clickListeners.map((listener) => listener({ target: {
    closest: (selector) => selector === '[data-job]' ? { dataset: { job: id } } : null,
  } })))
  return { run: (code) => vm.runInContext(code, ctx), el, ctx, clickJob, tick: () => pollTick() }
}

const settle = () => new Promise((r) => setImmediate(r))
async function loaded(d) {
  await d.run('hubReady')
  for (let i = 0; i < 20 && !d.run('jobs.length'); i++) await settle()
  for (let i = 0; i < 20; i++) await settle()
  return d
}

function modes(docs) {
  const local = localTree(docs)
  const hubRepo = { hub: JSON.stringify({ repo: 'o/r', overview: '/' }), '/api/repos/o/r/jobs': JSON.stringify({ jobs: docs.map((x) => hubJob(x)) }) }
  const hubAll = { hub: JSON.stringify({ repo: 'all', overview: '/' }), '/api/all/jobs': JSON.stringify({ jobs: docs.map((x) => hubJob(x, { id: 'r~' + x.id })) }) }
  return { local, hubRepo, hubAll }
}

const amount = (html, agent) => (html.match(new RegExp(agent + ' (\\$[\\d.,]+)')) || [])[1]

test('header, board, Costs table and charts use the same Agent split in every mode', async () => {
  const docs = FIXTURES.map((f) => f.doc)
  const want = FIXTURES.reduce((a, f) => ({ claude: a.claude + f.expect.claude, codex: a.codex + f.expect.codex }), { claude: 0, codex: 0 })
  for (const [mode, files] of Object.entries(modes(docs))) {
    const d = await loaded(dashboard(files))
    assert.equal(d.run('jobs.length'), docs.length, mode)
    const head = d.el('totals').textContent
    assert.match(head, new RegExp('claude \\$' + want.claude.toFixed(2) + ' · codex \\$' + want.codex.toFixed(2)), mode + ' header')
    // Costs table: the job columns, their totals and the sort by claude.
    d.run("costSort = { key: 'claude', dir: -1 }")
    const table = d.run('costsTables()')
    assert.match(table, new RegExp('claude \\$' + want.claude.toFixed(2) + ' · codex \\$' + want.codex.toFixed(2)), mode + ' tile')
    const order = [...table.matchAll(/<tr data-job="([^"]+)"/g)].map((m) => m[1].replace(/^r~/, ''))
    assert.equal(order[0], '014-total-only', mode + ' the $12 total-only job sorts first by claude')
    // Charts: each job's bar has its split, the same under both shadings.
    for (const shade of [false, true]) {
      const buckets = d.run('bucketList(jobs, "job", ' + shade + ')')
      for (const f of FIXTURES) {
        const b = buckets.find((x) => x.jobs[0].id.replace(/^r~/, '') === f.doc.id)
        sameSplit(b.parts, f.expect, mode + ' chart ' + f.doc.id + (shade ? ' by role' : ''))
      }
    }
    // Board rows and the drawer summary of the $12 job.
    const j = d.run("jobs.find((x) => x.title === 'total only')")
    const row = d.run('doneRow(jobs.find((x) => x.title === "total only"))')
    assert.equal(amount(row, 'claude'), '$12.00', mode + ' board row')
    assert.equal(amount(d.run('costTable(jobs.find((x) => x.title === "total only"))'), 'claude'), '$12.00', mode + ' drawer')
    assert.equal(d.run('agentCost(' + JSON.stringify({ cost_usd: 12 }) + ', "claude")'), 12, mode + ' subscription')
    assert.ok(j.id)
  }
})

test('renderers read summary fields, not the hub flag', async () => {
  const docs = FIXTURES.map((f) => f.doc)
  const d = await loaded(dashboard(modes(docs).hubAll))
  const render = () => d.run('chartSeq = 0; [boardPage(), costsTables(), costsFor(jobs, jobs)]')
  const under = await Promise.all(await render())
  d.run('hub = null')
  const without = await Promise.all(await render())
  assert.deepEqual(without, under)
  assert.match(under[0], /class="rchip" title="o\/r"/, 'all repos: a repo chip on each finished job')
})

test('a job hash link opens that job among duplicate keys, a late detail cannot replace another job', async () => {
  const doc = FIXTURES[0].doc
  const a = hubJob({ ...doc, title: 'on m1' }, { id: 'm1~' + doc.id, machine: 'm1' })
  const b = hubJob({ ...doc, title: 'on m2' }, { id: 'm2~' + doc.id, machine: 'm2' })
  let release
  const slow = new Promise((r) => { release = r })
  const files = { hub: JSON.stringify({ repo: 'o/r', overview: '/' }), '/api/repos/o/r/jobs': JSON.stringify({ jobs: [a, b] }),
    ['/api/repos/o/r/jobs/' + encodeURIComponent(a.id)]: async () => { await slow; return JSON.stringify({ ...a, files: [] }) },
    ['/api/repos/o/r/jobs/' + encodeURIComponent(b.id)]: JSON.stringify({ ...b, files: [] }) }
  const d = await loaded(dashboard(files))
  d.ctx.location.hash = '#job=' + encodeURIComponent(b.id)
  d.run('routeJob()')
  for (let i = 0; i < 10; i++) await settle()
  assert.equal(d.el('d-title').textContent, 'on m2', 'the hash opens the job of the machine it names')
  d.ctx.location.hash = '#job=' + encodeURIComponent(a.id)
  d.run('routeJob()') // its detail is slow to answer
  assert.equal(d.run('openJobId'), a.id)
  await d.run('openDrawer(' + JSON.stringify(b.id) + ')')
  release()
  for (let i = 0; i < 10; i++) await settle()
  assert.equal(d.run('openJobId'), b.id)
  assert.equal(d.el('d-title').textContent, 'on m2', 'the late reply for the other job is dropped')
})

test('hub drawer: a late detail error leaves the next job visible', async () => {
  const [a, b] = FIXTURES.slice(0, 2).map((f) => f.doc)
  let rejectDetail
  const slow = new Promise((_, reject) => { rejectDetail = reject })
  const files = modes([a, b]).hubRepo
  files['/api/repos/o/r/jobs/' + a.id] = () => slow
  files['/api/repos/o/r/jobs/' + b.id] = JSON.stringify({ ...hubJob(b), files: [] })
  const d = await loaded(dashboard(files))

  const openingA = d.clickJob(a.id)
  await d.clickJob(b.id)
  const shown = d.el('d-doc').innerHTML
  assert.equal(d.el('d-title').textContent, b.title)
  assert.ok(shown)

  rejectDetail(new Error('job A detail failed'))
  await openingA
  assert.equal(d.el('d-doc').innerHTML, shown)
})

test('hub drawer: a poll tick lets the pending detail finish', async () => {
  const doc = FIXTURES[0].doc
  const files = modes([doc]).hubRepo
  const detail = JSON.stringify({ ...hubJob(doc), files: [] })
  let finishFirst, finishLater
  const first = new Promise((resolve) => { finishFirst = resolve })
  const later = new Promise((resolve) => { finishLater = resolve })
  let requests = 0
  files['/api/repos/o/r/jobs/' + doc.id] = () => ++requests === 1 ? first : later
  const d = await loaded(dashboard(files))

  const opening = d.clickJob(doc.id)
  const poll = d.tick()
  try {
    await settle()
    finishFirst(detail)
    await opening
    assert.equal(d.el('d-title').textContent, doc.title)
    assert.equal(requests, 1)
  } finally {
    finishLater(detail)
    await poll
  }
  await d.tick()
  assert.equal(requests, 2, 'the next tick can refresh the drawer')
})

test('local drawer: a missing document keeps the unavailable state', async () => {
  const doc = { id: '030-x', title: 'x', stage: 'build', round: 1, started: '2026-11-18T10:00:00Z', cost_usd: 1 }
  const files = localTree([doc], { 'jobs/030-x/spec.md': '# Spec\n' })
  const d = await loaded(dashboard(files))
  await d.run('openDrawer("030-x")')
  assert.equal(d.run('openPath'), 'spec.md')
  assert.match(d.el('d-doc').innerHTML, /<h1>Spec<\/h1>|Spec/)
  delete files['jobs/030-x/spec.md']
  await d.run('openDrawer("030-x")')
  assert.match(d.el('d-doc').innerHTML, /<p class="note">jobs\/030-x\/spec.md: HTTP 404<\/p>/)
})
