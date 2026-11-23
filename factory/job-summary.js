// The job summary: one shape for a job in every view, with an Agent split computed locally
// or supplied by the hub (GLOSSARY.md). factory/dashboard.html and the hub's overview
// (hub/static/index.html) load it; factory/tests/job_summary.test.js runs it under node.
//
// A summary is the job's own fields plus
//   id         unique in the view: the job folder locally, the hub's served id (machine~key, repo~key)
//   repo       the job's repo on the hub (owner/name), null locally
//   repoLabel  the repo to show next to a job in a list: only when the view spans repos
//   cost_usd   the recorded total
//   split      {claude, codex, other}: the Agent split, see agentSplit
//   times      {total, work, wait} in ms
//   rounds     [{round, gate, reviews: {lens: verdict}}]: the Verdicts known for the job's rounds
// An adapter (local or hub) lists summaries and offers the drawer's detail operation:
//   list()                -> summaries
//   detail(summary)       -> {job: summary, files: [path], firstLine(path)}
//   read(summary, path)   -> the document's text; throws when it is missing
;(function (root) {
  const WAIT = new Set(['needs-human', 'paused', 'needs-info'])
  const TERMINAL = new Set(['merged', 'rejected'])
  const FINISHED_ROUND = new Set(['PASS', 'CHANGES'])
  const RESIDUE = 0.005

  const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : 0 }
  const isMap = (v) => v !== null && typeof v === 'object' && !Array.isArray(v)

  function fold(pairs) {
    const p = { claude: 0, codex: 0, other: 0 }
    for (const [agent, usd] of pairs) p[agent === 'claude' || agent === 'codex' ? agent : 'other'] += num(usd)
    return p
  }

  // A non-empty stored split wins, explicit zeroes included; else the priced rows; a job with only
  // a total is all claude (before 2026-11-12 the factory counted only Claude transcripts).
  // Unknown agents and what the total holds beyond the parts go to other; a residue under half a
  // cent is dropped. The recorded total is never changed.
  function agentSplit({ total, split, rows } = {}) {
    const t = num(total)
    const p = isMap(split) && Object.keys(split).length ? fold(Object.entries(split))
      : Array.isArray(rows) && rows.length ? fold(rows.map((r) => [r && r.agent, r && r.cost_usd]))
      : { claude: t, codex: 0, other: 0 }
    const rest = t - p.claude - p.codex - p.other
    // Subtracting dollar amounts can put an exact half cent just below the cutoff.
    const rounding = Number.EPSILON * Math.max(Math.abs(t), Math.abs(p.claude), Math.abs(p.codex), Math.abs(p.other))
    if (rest > 0 && rest >= RESIDUE - rounding) p.other += Math.max(rest, RESIDUE)
    return p
  }

  // Time a job spent working and waiting on a human, from its history.
  function timesOf(job, now = Date.now()) {
    const h = Array.isArray(job.history) ? job.history : []
    const end = job.ended ? Date.parse(job.ended) : now
    let wait = 0
    h.forEach((e, i) => {
      const to = i + 1 < h.length ? Date.parse(h[i + 1].at) : (TERMINAL.has(e.stage) ? Date.parse(e.at) : end)
      if (WAIT.has(e.stage)) wait += to - Date.parse(e.at)
    })
    const total = job.started ? end - Date.parse(job.started) : 0
    return { total, wait, work: Math.max(0, total - wait) }
  }

  // Verdicts must match the artifact kind and come from the first line.
  const DECLARATIONS = {
    review: /^VERDICT:\p{White_Space}*(PASS|CHANGES)$/u,
    checks: /^GATE:\p{White_Space}*(PASS|FAIL)$/u,
  }

  function verdictOf(kind, line) {
    if (line === null || line === undefined) return 'pending'
    const m = line.replace(/^\p{White_Space}+|\p{White_Space}+$/gu, '').match(DECLARATIONS[kind])
    return m ? m[1] : 'invalid'
  }

  function roundArtifactKind(path) {
    if (/^round-\d+\/(merge-)?checks\.md$/.test(path)) return 'checks'
    if (/^round-\d+\/review-[^/]+\.md$/.test(path)) return 'review'
    return null
  }

  // A raw job.json, as factory/bin/job writes it. rounds: what the adapter read from the round files.
  function fromLocal(doc, { rounds = [], now } = {}) {
    return { ...doc, id: String(doc.id), repo: null, repoLabel: null, cost_usd: num(doc.cost_usd),
      split: agentSplit({ total: doc.cost_usd, split: doc.cost_by_agent, rows: doc.cost_breakdown }),
      times: timesOf(doc, now), rounds }
  }

  // A hub job summary (hub/API.md). The hub applies the Agent split rule at projection time.
  // repo: the view's repo, or 'all'.
  function fromHub(doc, { repo = 'all', now } = {}) {
    const timed = doc.work_s !== null && doc.work_s !== undefined && doc.wait_s !== null && doc.wait_s !== undefined
    const rounds = (Array.isArray(doc.rounds) ? doc.rounds : []).map((r) => ({
      round: r.round, gate: r.gate || 'pending', reviews: isMap(r.reviews) ? { ...r.reviews } : {} }))
    const repoName = repo === 'all' ? (doc.repo || null) : repo
    return { ...doc, id: String(doc.id), repo: repoName, repoLabel: repo === 'all' ? repoName : null,
      cost_usd: num(doc.cost_usd),
      split: doc.cost_by_agent,
      times: timed ? { total: num(doc.duration_s) * 1000, work: num(doc.work_s) * 1000, wait: num(doc.wait_s) * 1000 } : timesOf(doc, now),
      rounds }
  }

  // The verdicts of round n, every routed reviewer listed ('pending' until its file says otherwise).
  function roundOf(job, n) {
    const r = (job.rounds || []).find((x) => x.round === n)
    const lenses = Object.keys((job.agents && job.agents.reviewers) || {})
    return { gate: (r && r.gate) || 'pending',
      reviews: Object.fromEntries(lenses.map((l) => [l, (r && r.reviews && r.reviews[l]) || 'pending'])) }
  }

  // The links of a directory index (python -m http.server and the hub's tree write the same).
  const links = (html) => [...String(html).matchAll(/<a href="([^"]*)"/g)].map((m) => decodeURIComponent(m[1]))

  // The first line a round file of the job declares, as its Verdict says, for a file not read yet.
  function verdictLine(job, path) {
    const m = path.match(/^round-(\d+)\/(checks|review-(.+))\.md$/)
    if (!m) return null
    const r = (job.rounds || []).find((x) => x.round === Number(m[1]))
    const v = m[2] === 'checks' ? r && r.gate : r && r.reviews && r.reviews[m[3]]
    return v && v !== 'pending' ? `${m[2] === 'checks' ? 'GATE' : 'VERDICT'}: ${v}` : null
  }

  function documents(fetchText, firstLines) {
    return async (job, path) => {
      const kind = roundArtifactKind(path)
      const text = await fetchText(`jobs/${job.id}/${path}`, kind)
      firstLines.set(`${job.id}/${path}`, text.split('\n', 1)[0])
      return text
    }
  }

  // Static local serving: factory/bin/dashboard or python -m http.server in factory/.
  function localAdapter({ fetchText }) {
    const roundCache = new Map() // "<job>/<n>" -> verdicts of a settled earlier round
    const firstLines = new Map()
    const read = documents(fetchText, firstLines)
    const first = async (url, kind) => {
      try { return (await fetchText(url, kind)).split('\n', 1)[0] }
      catch (err) { return err.status && err.status !== 404 ? '' : null }
    }
    async function readRound(doc, n) {
      const key = `${doc.id}/${n}`
      if (roundCache.has(key)) return roundCache.get(key)
      const dir = `jobs/${doc.id}/round-${n}/`
      const v = { round: n, gate: verdictOf('checks', await first(dir + 'checks.md', 'checks')), reviews: {} }
      if (v.gate === 'PASS') {
        await Promise.all(Object.keys((doc.agents && doc.agents.reviewers) || {}).map(async (r) => {
          v.reviews[r] = verdictOf('review', await first(`${dir}review-${r}.md`, 'review'))
        }))
      }
      const settled = v.gate === 'FAIL' || (v.gate === 'PASS' && Object.values(v.reviews).every((x) => FINISHED_ROUND.has(x)))
      if (settled && n < doc.round) roundCache.set(key, v)
      return v
    }
    async function listFiles(dir) {
      const out = []
      for (const h of links(await fetchText(dir))) {
        if (h.endsWith('/')) out.push(...(await listFiles(dir + h)).map((f) => h + f))
        else if (h.endsWith('.md')) out.push(h)
      }
      return out
    }
    return {
      async list() {
        let listing
        try { listing = await fetchText('jobs/') } catch { return [] }
        const ids = links(listing).filter((h) => h.endsWith('/')).map((h) => h.slice(0, -1))
          .filter((id) => !id.startsWith('_')).sort() // _features/ and other _ folders hold factory state
        return Promise.all(ids.map(async (id) => {
          const doc = JSON.parse(await fetchText(`jobs/${id}/job.json`))
          // Only a job still in flight shows its round's Verdicts; a finished one shows its history.
          const rounds = doc.round && !TERMINAL.has(doc.stage) ? [await readRound(doc, doc.round)] : []
          return fromLocal(doc, { rounds })
        }))
      },
      async detail(job) {
        const files = await listFiles(`jobs/${job.id}/`)
        await Promise.all(files.filter((f) => !firstLines.has(`${job.id}/${f}`)).map(async (f) => {
          firstLines.set(`${job.id}/${f}`, await first(`jobs/${job.id}/${f}`, roundArtifactKind(f)))
        }))
        return { job, files, firstLine: (f) => firstLines.get(`${job.id}/${f}`) }
      },
      read,
    }
  }

  // The hub: /r/<owner>/<name>/ (repo 'owner/name') or /all/ (repo 'all').
  function hubAdapter({ fetchText, repo }) {
    const firstLines = new Map()
    const api = repo === 'all' ? '/api/all/jobs' : `/api/repos/${repo.split('/').map(encodeURIComponent).join('/')}/jobs`
    return {
      async list() {
        return JSON.parse(await fetchText(api)).jobs.map((j) => fromHub(j, { repo }))
      },
      async detail(job) {
        const fresh = fromHub(JSON.parse(await fetchText(`${api}/${encodeURIComponent(job.id)}`)), { repo })
        const files = (fresh.files || []).filter((f) => String(f).endsWith('.md'))
        return { job: fresh, files, firstLine: (f) => verdictLine(fresh, f) ?? firstLines.get(`${fresh.id}/${f}`) }
      },
      read: documents(fetchText, firstLines),
    }
  }

  const api = { agentSplit, timesOf, verdictOf, roundArtifactKind, roundOf, fromLocal, fromHub, localAdapter, hubAdapter, links }
  if (typeof module === 'object' && module.exports) module.exports = api
  else root.JobSummary = api
})(typeof self !== 'undefined' ? self : this)
