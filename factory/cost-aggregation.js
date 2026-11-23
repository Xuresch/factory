// Cost calculations shared by the dashboard and hub overview. For a job, only its
// resolved summary split supplies agent totals. Priced rows supply role and model detail.
;(function (root) {
  const AGENTS = Object.freeze(['claude', 'codex', 'other'])
  const HALF_CENT = 0.005
  // Use the job summary's relative rounding tolerance at the half-cent boundary.
  // Aggregates and shares keep the raw amounts.
  function displayAmount(usd) {
    const rounding = 4 * Number.EPSILON * Math.max(Math.abs(usd), HALF_CENT)
    return usd > 0 && usd < HALF_CENT && usd >= HALF_CENT - rounding ? HALF_CENT : usd
  }
  const emptySplit = () => ({ claude: 0, codex: 0, other: 0 })
  const amount = (v) => Number.isFinite(Number(v)) ? Number(v) : 0
  const agentKey = (a) => a === 'claude' || a === 'codex' ? a : 'other'
  const splitTotal = (split) => AGENTS.reduce((sum, agent) => sum + amount(split?.[agent]), 0)
  const percent = (part, total) => total ? Math.round(100 * part / total) : 0

  function display(sources) {
    const split = emptySplit()
    for (const [, values] of sources) {
      for (const agent of AGENTS) split[agent] += amount(values?.[agent])
    }
    const total = splitTotal(split)
    const agents = AGENTS.filter((agent) => displayAmount(split[agent]) >= HALF_CENT)
      .map((agent) => ({ agent, amount: split[agent], percent: percent(split[agent], total) }))
    const segments = agents.flatMap(({ agent }) => sources
      .map(([source, values]) => ({ agent, amount: amount(values?.[agent]), source }))
      .filter(({ amount }) => amount > 0))
    return { total, agents, segments }
  }

  const splitDisplay = (split) => display([[null, split]])
  const sourceSplitDisplay = (factory, outside) => display([['factory', factory], ['outside', outside]])

  function jobTotals(jobs) {
    const split = emptySplit()
    let total = 0
    for (const job of jobs) {
      total += amount(job.cost_usd)
      for (const agent of AGENTS) split[agent] += amount(job.split?.[agent])
    }
    return { total, split }
  }

  const shortModel = (m) => String(m || '?').replace(/^claude-/, '').replace(/-\d+(-\d+)*$/, '')
  const modelKey = (row) => `${row.agent} · ${shortModel(row.model)}`
  const pricedRows = (job) => job.cost_breakdown || []

  function jobCosts(job) {
    const rows = pricedRows(job)
    return { rows, total: rows.reduce((total, row) => total + amount(row.cost_usd), 0) }
  }

  function groupRows(rows, keyOf) {
    const groups = new Map()
    for (const row of rows) {
      const key = keyOf(row)
      const group = groups.get(key) || { key, sessions: 0, input: 0, cached: 0, output: 0, cost: 0, jobs: new Set() }
      group.sessions += amount(row.sessions)
      group.input += amount(row.input_tokens)
      group.cached += amount(row.cached_tokens)
      group.output += amount(row.output_tokens)
      group.cost += amount(row.cost_usd)
      group.jobs.add(row.job)
      groups.set(key, group)
    }
    return [...groups.values()].sort((a, b) => b.cost - a.cost)
  }

  function tableCosts(jobs) {
    const rows = jobs.flatMap((job) => pricedRows(job).map((row) => ({ ...row, job: job.id })))
    return {
      rows,
      byModel: groupRows(rows, modelKey),
      byRole: groupRows(rows, (row) => String(row.role).replace(/-s\d+$/, ' (slices)')),
    }
  }

  // Role order breaks ties in the role chart. Shade 0 is darkest.
  const ROLES = {
    builder: { label: 'builder', shade: 0 },
    'spec-writer': { label: 'spec', shade: 1 },
    intake: { label: 'intake', shade: 3 },
    'reviewer-code': { label: 'code review', shade: 2 },
    approver: { label: 'approver', shade: 3 },
    other: { label: 'ux · ui · security', shade: 2 },
  }
  const roleKey = (role) => {
    const key = String(role).replace(/-s\d+$/, '')
    return Object.hasOwn(ROLES, key) ? key : 'other'
  }

  function roleAmounts(job, { useJobRoleMix = false } = {}) {
    const rows = pricedRows(job).filter((row) => amount(row.cost_usd) > 0)
    return AGENTS.flatMap((agent) => {
      const cost = amount(job.split?.[agent])
      if (!cost) return []
      const own = rows.filter((row) => agentKey(row.agent) === agent)
      // Cost per role uses the job's role mix for an agent without priced rows.
      // Time buckets keep the default shade for that agent.
      const weights = !own.length && useJobRoleMix ? rows : own
      if (!weights.length) return [{ agent, key: null, shade: 1, cost }]
      const total = weights.reduce((sum, row) => sum + amount(row.cost_usd), 0)
      return weights.map((row) => {
        const key = roleKey(row.role)
        return { agent, key, shade: ROLES[key].shade, model: own.length ? modelKey(row) : null,
          cost: cost * (amount(row.cost_usd) / total) }
      })
    })
  }

  function roleCosts(jobs) {
    const groups = new Map()
    for (const job of jobs) {
      for (const { agent, key, model, cost } of roleAmounts(job, { useJobRoleMix: true })) {
        if (key === null) continue // The job has an Agent split but no priced role.
        const group = groups.get(key) || { key, label: ROLES[key].label, split: emptySplit(), models: new Map() }
        group.split[agent] += cost
        if (model) {
          const priced = group.models.get(model) || { agent, cost: 0 }
          priced.cost += cost
          group.models.set(model, priced)
        }
        groups.set(key, group)
      }
    }
    return Object.keys(ROLES).filter((key) => groups.has(key)).map((key) => groups.get(key))
      .sort((a, b) => splitTotal(b.split) - splitTotal(a.split))
  }

  function costBuckets(jobs, unit, byRole, from, to) {
    const ordered = [...jobs].sort((a, b) => String(a.started).localeCompare(String(b.started)))
    if (unit === 'job') return ordered.map((job) => bucketCosts({ jobs: [job] }, byRole))
    if (!ordered.length && !(from && to)) return []

    const startOf = (iso) => {
      const date = new Date(iso)
      date.setHours(0, 0, 0, 0)
      if (unit === 'week') date.setDate(date.getDate() - ((date.getDay() + 6) % 7))
      return date
    }
    const first = startOf(from ?? ordered[0]?.started)
    const last = startOf(to ?? ordered[ordered.length - 1]?.started)
    const buckets = new Map()
    for (let date = first; date <= last; date.setDate(date.getDate() + (unit === 'week' ? 7 : 1))) {
      buckets.set(date.getTime(), { start: date.getTime(), jobs: [] })
    }
    for (const job of ordered) buckets.get(startOf(job.started).getTime())?.jobs.push(job)
    return [...buckets.values()].map((bucket) => bucketCosts(bucket, byRole))
  }

  function bucketCosts(bucket, byRole) {
    const { split } = jobTotals(bucket.jobs)
    const { agents, total, segments } = splitDisplay(split)
    const steps = [0, 0, 0, 0]
    if (!byRole) return { ...bucket, split, agents, total, segments, steps }

    const shades = { claude: [...steps], codex: [...steps], other: [...steps] }
    for (const job of bucket.jobs) {
      for (const { agent, shade, cost } of roleAmounts(job)) shades[agent][shade] += cost
    }
    const shaded = agents.flatMap(({ agent, amount }) => {
      const row = shades[agent]
      row.forEach((cost, shade) => { steps[shade] += cost })
      return agent === 'other' ? [{ agent, amount }]
        : row.flatMap((cost, shade) => cost > 0 ? [{ agent, amount: cost, shade }] : [])
    })
    return { ...bucket, split, agents, total, segments: shaded, steps }
  }

  const api = { AGENTS, agentKey, percent, splitTotal, displayAmount, splitDisplay, sourceSplitDisplay, jobTotals, shortModel,
    modelKey, jobCosts, tableCosts, roleCosts, costBuckets }
  if (typeof module === 'object' && module.exports) module.exports = api
  else root.CostAggregation = api
})(typeof self !== 'undefined' ? self : this)
