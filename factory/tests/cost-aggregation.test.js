const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const vm = require('node:vm')
const JobSummary = require('../job-summary.js')
const fixtures = require('./job_summary_fixtures.json')
const { splitDisplay, sourceSplitDisplay, jobTotals, jobCosts, tableCosts, roleCosts, costBuckets } = require('../cost-aggregation.js')

const agents = (display) => display.agents.map(({ agent }) => agent)
const pairs = (groups) => groups.map(({ key, cost }) => [key, cost])

test('only agents with half a cent or more are selected, and shares include hidden amounts', () => {
  const split = { claude: 0, codex: 0.004, other: 0.0045 }
  assert.deepEqual(splitDisplay(split).agents, [])
  assert.equal(splitDisplay(split).total, 0.0085)
  for (const agent of Object.keys(split)) {
    const display = splitDisplay({ ...split, [agent]: 0.005 })
    assert.deepEqual(agents(display), [agent])
    assert.deepEqual(display.segments.map(({ agent, amount }) => [agent, amount]), [[agent, 0.005]])
  }
  assert.equal(splitDisplay({ ...split, claude: 0.005 }).agents[0].percent, 37)
  const jobs = [
    { id: 'a', started: '2026-11-02T12:00:00', split: { claude: 0.003, codex: 0.0045 } },
    { id: 'b', started: '2026-11-02T13:00:00', split: { claude: 0.002 } },
  ]
  assert.equal(costBuckets(jobs, 'job', true).flatMap(({ segments }) => segments).length, 0)
  const [day] = costBuckets(jobs, 'day', true)
  assert.deepEqual(day.segments, [{ agent: 'claude', amount: 0.005, shade: 1 }])
  assert.equal(day.total, 0.0095)
})

test('source segments use the combined agent total and keep every positive source', () => {
  const display = sourceSplitDisplay(
    { claude: 0.003, codex: 0.006, other: 0.0045 },
    { claude: 0.003, codex: 0.001, other: 0 },
  )
  assert.deepEqual(agents(display), ['claude', 'codex'])
  assert.deepEqual(display.segments.map(({ agent, amount, source }) => [agent, amount, source]), [
    ['claude', 0.003, 'factory'], ['claude', 0.003, 'outside'],
    ['codex', 0.006, 'factory'], ['codex', 0.001, 'outside'],
  ])
  assert.deepEqual(sourceSplitDisplay({ claude: 0.005 }, { claude: 0 }).segments
    .map(({ source }) => source), ['factory'])
})

const row = (role, agent, model, cost_usd) => ({ role, agent, model, cost_usd, sessions: 1, input_tokens: 100 })
test('half-cent source and role amounts stay visible after floating-point arithmetic', () => {
  const month = sourceSplitDisplay({ claude: 0.0005 }, { claude: 0.0045 })
  assert.ok(Math.abs(month.total - 0.005) < 1e-12)
  assert.deepEqual(agents(month), ['claude'])
  assert.deepEqual(month.segments.map(({ amount }) => amount), [0.0005, 0.0045])

  const job = JobSummary.fromLocal({ id: 'half-cent', cost_usd: 0.019, cost_breakdown: [
    row('builder', 'claude', 'sonnet', 0.005),
    row('approver', 'claude', 'sonnet', 0.014),
  ] })
  const builder = roleCosts([job]).find(({ key }) => key === 'builder')
  assert.deepEqual(agents(splitDisplay(builder.split)), ['claude'])
  assert.deepEqual(agents(splitDisplay({ claude: 0.004999 })), [])
})

const jobs = [
  JobSummary.fromLocal({ id: '001', started: '2026-11-02T12:00:00', cost_usd: 10, cost_breakdown: [
    row('builder-s1', 'claude', 'claude-opus-4', 2),
    row('builder-s2', 'claude', 'claude-opus-4', 1),
    row('reviewer-code', 'claude', 'claude-sonnet-4', 3),
    row('reviewer-ux', 'another-agent', 'custom-model', 4),
  ] }),
  JobSummary.fromLocal({ id: '002', started: '2026-11-16T12:00:00', cost_usd: 5, cost_breakdown: [
    row('approver', 'codex', 'gpt', 5),
  ] }),
]

test('job detail keeps the priced rows and All tables roll up slices and models', () => {
  const { rows, total } = jobCosts(jobs[0])
  assert.deepEqual(rows.map(({ role, agent, model }) => [role, agent, model]), [
    ['builder-s1', 'claude', 'claude-opus-4'],
    ['builder-s2', 'claude', 'claude-opus-4'],
    ['reviewer-code', 'claude', 'claude-sonnet-4'],
    ['reviewer-ux', 'another-agent', 'custom-model'],
  ])
  assert.equal(total, 10)
  const tables = tableCosts(jobs)
  assert.deepEqual(pairs(tables.byRole), [['approver', 5], ['reviewer-ux', 4], ['builder (slices)', 3], ['reviewer-code', 3]])
  assert.deepEqual(pairs(tables.byModel), [['codex · gpt', 5], ['another-agent · custom-model', 4], ['claude · opus', 3], ['claude · sonnet', 3]])
  const slices = tables.byRole[2]
  assert.deepEqual([slices.jobs.size, slices.sessions, slices.input], [1, 2, 200])
})

test('role groups and job, day and week buckets preserve agent totals and empty slots', () => {
  assert.deepEqual(roleCosts(jobs).map(({ key, split }) => [key, split]), [
    ['approver', { claude: 0, codex: 5, other: 0 }],
    ['other', { claude: 0, codex: 0, other: 4 }],
    ['builder', { claude: 3, codex: 0, other: 0 }],
    ['reviewer-code', { claude: 3, codex: 0, other: 0 }],
  ])
  for (const [unit, count] of [['job', 2], ['day', 15], ['week', 3]]) {
    const plain = costBuckets(jobs, unit, false)
    const shaded = costBuckets(jobs, unit, true)
    assert.equal(shaded.length, count)
    assert.deepEqual(shaded.map((b) => b.total), [10, ...Array(count - 2).fill(0), 5])
    assert.deepEqual(shaded.map((b) => b.split), plain.map((b) => b.split))
    assert.deepEqual(plain[0].segments.map(({ agent, amount }) => [agent, amount]), [['claude', 6], ['other', 4]])
    assert.deepEqual(shaded[0].segments.map(({ agent, shade, amount }) => [agent, shade, amount]), [
      ['claude', 0, 3], ['claude', 2, 3], ['other', undefined, 4],
    ])
  }
})

test('roles and buckets use the summary split when priced rows name another agent', () => {
  const { doc } = fixtures.jobs.find(({ doc }) => doc.id === '010-split-wins')
  const job = JobSummary.fromLocal(doc)
  const roles = roleCosts([job])
  assert.deepEqual(roles.map(({ split }) => split), [{ claude: 0, codex: 5, other: 0 }])
  for (const unit of ['job', 'day', 'week']) {
    const [bucket] = costBuckets([job], unit, true)
    assert.deepEqual(bucket.split, { claude: 0, codex: 5, other: 0 })
    assert.deepEqual(bucket.segments, [{ agent: 'codex', amount: 5, shade: 1 }])
    assert.deepEqual(bucket.steps, [0, 5, 0, 0])
  }
  assert.equal(jobCosts(job).rows[0].agent, 'claude')
})

test('local and hub summaries supply legacy attribution and explicit zeros', () => {
  for (const doc of [
    { id: 'legacy', cost_usd: 7 },
    { id: 'explicit', cost_usd: 5, cost_by_agent: { claude: 0, codex: 5 }, cost_breakdown: [row('builder', 'claude', 'opus', 5)] },
  ]) {
    const local = JobSummary.fromLocal(doc)
    const hub = JobSummary.fromHub({ ...doc, cost_split: doc.cost_by_agent })
    const expected = doc.id === 'legacy' ? ['claude'] : ['codex']
    assert.deepEqual(agents(splitDisplay(local.split)), expected)
    assert.deepEqual(splitDisplay(local.split), splitDisplay(hub.split))
    if (doc.id === 'legacy') assert.deepEqual(roleCosts([local]), [])
  }
  assert.deepEqual(jobTotals([{ cost_usd: 7 }]), { total: 7, split: { claude: 0, codex: 0, other: 0 } })
  const bare = { id: 'bare', cost_usd: 7, cost_breakdown: [row('builder', 'claude', 'opus', 7)] }
  assert.equal(splitDisplay(bare.split).total, 0)
  assert.deepEqual(roleCosts([bare]), [])
  assert.equal(costBuckets([bare], 'job', false)[0].total, 0)
})

const overviewPath = path.join(__dirname, '../../hub/static/index.html')
test('hub overview renders both monthly sources and uses the job summary on finished rows', {
  skip: !fs.existsSync(overviewPath),
}, () => {
  const html = fs.readFileSync(overviewPath, 'utf8')
  const listeners = new Map()
  const main = { clientWidth: 1000, querySelectorAll: () => [] }
  const ctx = vm.createContext({
    document: { getElementById: () => main, querySelectorAll: () => [], addEventListener() {},
      createElement: () => ({ setAttribute() {} }), body: { append() {} } },
    location: { search: '', hash: '' }, URLSearchParams, innerWidth: 1000, addEventListener() {}, setInterval() {},
    FactoryNav: { on: (event, listener) => listeners.set(event, listener), setSub() {} },
  })
  ctx.self = ctx.window = ctx
  for (const [, src] of html.matchAll(/<script src="\/all\/([^"]+)"><\/script>/g)) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, '..', src), 'utf8'), ctx, { filename: src })
  }
  vm.runInContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], ctx)
  const docs = fixtures.jobs.filter(({ doc }) => ['010-split-wins', '014-total-only'].includes(doc.id))
  listeners.get('data')({
    machines: [{ machine: 'm1' }], repos: [], needs_you: [], live: [], events: [],
    recent: docs.map(({ doc }) => ({ repo: 'o/r', job: { ...doc, cost_split: doc.cost_by_agent } })),
    month: { api_equivalent_usd: 0.0095, factory: { claude: 0.0005, codex: 0.0045 }, outside: { claude: 0.0045 } },
  })
  const monthly = main.innerHTML.match(/<div class="tile spend">[\s\S]*?<div class="pace">/)[0]
  assert.match(monthly, /aria-label="claude \$0\.01" title="claude \$0\.01 \(53%\)"/)
  assert.match(monthly, /class="c" style="flex:0\.0005 1 0"><\/i><i class="c out" style="flex:0\.0045 1 0"/)
  assert.match(monthly, /class="lg"><span><span class="sw c" aria-hidden="true"><\/span>claude \$0\.01<\/span><\/span>/)
  assert.doesNotMatch(monthly, /codex|class="x"/)
  assert.match(main.innerHTML, /title="split wins"[\s\S]*?aria-label="codex \$5\.00"/)
  assert.match(main.innerHTML, /title="total only"[\s\S]*?aria-label="claude \$12\.00"/)
})
