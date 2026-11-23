import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { compileFunction, createContext, runInContext } from 'node:vm'
import JobSummary from '../job-summary.js'
import CostAggregation from '../cost-aggregation.js'

const dashboard = readFileSync(new URL('../dashboard.html', import.meta.url), 'utf8')
const overview = readFileSync(new URL('../../hub/static/index.html', import.meta.url), 'utf8')
const planCode = dashboard.slice(dashboard.indexOf('let lastPlan'), dashboard.indexOf('// #job=<id>'))
const overviewCode = overview.slice(overview.indexOf('const monthName'), overview.indexOf('  const oldestWait'))
const overviewSplit = overview.slice(overview.indexOf('const agentCls'), overview.indexOf('// ---- Pieces'))
const helpers = `
  const esc = String
  const plural = (n, word) => n + ' ' + word
`
const compilePlan = (legacy = false) => {
  const parsingContext = createContext()
  if (legacy) runInContext('delete Array.prototype.toReversed', parsingContext)
  return compileFunction(`${helpers}
  ${dashboard.match(/^const money = .*$/m)[0]}
  const { AGENTS: SPLIT_AGENTS, percent: pct } = CostAggregation
  const ui = { range: 'all' }, RANGES = { all: 0 }
  const sw = () => '', deltaHtml = () => '', niceAxis = () => ({ max: 1000 }), axisFmt = money
  const plotWidth = () => 720, barChart = () => '', rangeControl = () => '', tokens = String
  ${planCode}
  return async () => { await loadPlan(); return planPage() }
`, ['JobSummary', 'CostAggregation', 'fetch', 'Date'], { parsingContext })
}
const fetchPlan = compilePlan()
const renderOverview = new Function('data', 'CostAggregation', `${helpers}
  ${overview.match(/^const money = .*$/m)[0]}
  const { displayAmount, splitDisplay, sourceSplitDisplay } = CostAggregation
  const nav = { setSub() {} }
  ${overviewSplit}
  ${overviewCode}
  return spend }
  return render()
`)

const fixed = Date.parse('2026-11-16T00:00:00Z')
class FixtureDate extends Date {
  constructor(...args) { super(...(args.length ? args : [fixed])) }
  static now() { return fixed }
}
const renderPlans = (document, clock = FixtureDate, renderer = fetchPlan) => renderer(JobSummary, CostAggregation,
  async () => new Response(JSON.stringify(document)), clock)()

const standalone = {
  subscriptions: [{ name: 'Claude', agent: 'claude', usd_per_month: 120 }],
  projects: [{ name: 'local', jobs: [{ started: '2026-11-10T10:00:00Z', cost_usd: 50 }] }],
  config: '/fixture/subscriptions.json', outside: { status: 'ready', months: { '2026-11': { claude: 10 } } },
}
assert.match(await renderPlans(standalone), /\$60\.00<\/b> API-equivalent/)
assert.match(await renderPlans({ configured: false, config: standalone.config }), /Create <code>\/fixture\/subscriptions\.json<\/code>/)

test('standalone Plans renders without Array.prototype.toReversed', async () => {
  assert.match(await renderPlans(standalone, FixtureDate, compilePlan(true)), /\$60\.00<\/b> API-equivalent/)
})

test('both hub views retain cents below $100', async () => {
  const split = { claude: 99.75, codex: 0, other: 0 }
  const empty = { claude: 0, codex: 0, other: 0 }
  const month = {
    month: '2026-11', api_equivalent_usd: 99.75, jobs: 1, elapsed_share: 0.5,
    factory_usd: 99.75, outside_usd: 0, by_agent: split, factory: split, outside: empty,
    plan_fee_full_usd: 0, plan_fee_elapsed_usd: 0, plan_fee_elapsed_by_agent: empty,
  }
  const overviewData = { machines: [{}], repos: [], merged_week: 0, needs_you: [], live: [], month }
  const plans = { subscriptions: [], projects: [], comparison: {
    now: '2026-11-16T00:00:00Z', current_month: '2026-11', months: { '2026-11': month },
  } }
  assert.match(await renderPlans(plans), /<b>\$99\.75<\/b> API-equivalent/)
  assert.match(renderOverview(overviewData, CostAggregation), /<div class="v">\$99\.75<\/div>/)
})

if (process.argv.includes('--hub')) {
  const { overview, plans } = JSON.parse(readFileSync(0, 'utf8'))
  assert.equal(new Date(`${plans.comparison.current_month}-01T00:30:00Z`).getDate() >= 28, true)
  const board = renderOverview(overview, CostAggregation)
  const page = await renderPlans(plans, Date)
  const monthStart = new Date(`${plans.comparison.current_month}-01T00:00:00Z`)
  const monthLabel = monthStart.toLocaleDateString([], { month: 'short', year: 'numeric', timeZone: 'UTC' })
  assert.ok(page.includes(`<h3>${monthLabel} so far, by agent</h3>`))
  assert.match(board, /\$60\.00/)
  assert.match(page, /\$60\.00<\/b> API-equivalent/)
  for (const html of [board, page]) {
    assert.match(html, /other \$30\.00|other\s+\$30\.00|other[\s\S]*?\$30\.00/)
    assert.match(html, /Full Plan fee <b>\$120<\/b>/)
    assert.match(html, /Elapsed Plan fee <b>\$[\d.]+<\/b>/)
  }
  if ('monthly_pace_usd' in overview.month) {
    const pace = /Monthly pace <b>(\$[\d,.]+)<\/b>/.exec(board)?.[1]
    assert.ok(pace)
    assert.ok(page.includes(`Monthly pace <b>${pace}</b>`))
  } else {
    assert.doesNotMatch(board + page, /Monthly pace <b>/)
  }
}
console.log('ok: subscription views and standalone configuration')
