/* Factory hub app bar. One implementation, loaded by the overview and, once the `hub` probe
 * answers, by dashboard.html. It owns what both pages share: the bar (mark, scope switcher, view
 * tabs, search, needs-you badge, live status), the machines popover (freshness per source), the quick-jump palette, the page title and the
 * connection to the hub (/api/overview + /api/stream).
 *
 *   FactoryNav.data            latest /api/overview (null until the first answer)
 *   FactoryNav.on(type, fn)    'data' (replays the latest), 'job' (a stage change), 'seen' (a heartbeat)
 *   FactoryNav.setSub(text)    the line under the page title
 *   FactoryNav.pageError(msg)  the page's own data failed (or null: it works again)
 *   FactoryNav.fail            true once the bar could not mount; pages fall back to their own header
 */
(() => {
  if (window.FactoryNav) return
  const me = document.currentScript
  const ROOT = new URL('../', me && me.src ? me.src : location.href).pathname      // '/'
  const LIVE = new Set(['intake', 'spec', 'build', 'gate', 'review', 'approve', 'merging'])
  const STALE_S = 900
  const $ = (sel, el = document) => el.querySelector(sel)
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c])
  const safe = (h) => /^(\/(?!\/)|https?:\/\/)/.test(String(h || ''))
  const plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`
  const t = (iso) => Date.parse(iso)
  const dec = (s) => { try { return decodeURIComponent(s) } catch { return s } }

  // ---- Where am I ---------------------------------------------------------------------------

  const allBase = `${ROOT}all/dashboard.html`
  const repoBase = (repo) => `${ROOT}r/${String(repo).split('/').map(encodeURIComponent).join('/')}/dashboard.html`
  const VIEWS = { overview: 'Overview', board: 'Board', costs: 'Costs', plan: 'Subscription' }

  function where() {
    const p = location.pathname.slice(ROOT.length - 1)
    const m = p.match(/^\/r\/([^/]+)\/([^/]+)\//)
    if (m) return { page: 'dash', scope: 'repo', repo: `${dec(m[1])}/${dec(m[2])}` }
    if (/^\/all\//.test(p)) return { page: 'dash', scope: 'all' }
    return { page: 'overview', scope: 'all' }
  }
  const at = where()
  const viewNow = () => at.page === 'overview' ? 'overview' : ({ '#costs': 'costs', '#plan': 'plan' })[location.hash] || 'board'
  // The subscription is always across repos: a repo page asked for it goes to the global one.
  const redirectPlan = () => { if (at.scope === 'repo' && location.hash === '#plan') location.replace(`${allBase}#plan`) }
  redirectPlan()

  // The address of a view in a scope. A repo has no overview or subscription of its own.
  function href(scope, view) {
    if (scope === 'all') return view === 'overview' ? ROOT : `${allBase}#${view}`
    return `${repoBase(scope)}#${view === 'costs' ? 'costs' : 'board'}`
  }
  const tabs = at.scope === 'all'
    ? [['overview', ROOT], ['board', `${allBase}#board`], ['costs', `${allBase}#costs`], ['plan', `${allBase}#plan`]]
    : [['board', `${repoBase(at.repo)}#board`], ['costs', `${repoBase(at.repo)}#costs`], ['plan', `${allBase}#plan`]]

  const rshort = (r) => String(r).split('/').pop()
  const scopeLabel = () => (at.scope === 'all' ? 'All repos' : rshort(at.repo))
  const ownerOf = (r) => { const p = String(r).split('/'); return p.length > 1 ? `${p[0]}/` : '' }

  // ---- Data and connection ------------------------------------------------------------------

  const nav = {
    data: null, fail: false,
    sync: { conn: 'wait', at: null, err: null, down: null, auth: false },
    pageErr: null, subs: { data: [], job: [], seen: [] },
  }
  nav.on = (type, fn) => { nav.subs[type].push(fn); if (type === 'data' && nav.data) fn(nav.data) }
  const emit = (type, v) => nav.subs[type].forEach((fn) => { try { fn(v) } catch (e) { console.error(e) } })
  nav.setSub = (text) => { const el = $('#nb-sub'); if (el && el.textContent !== text) el.textContent = text }
  // A failed page fetch may be an expired sign-in: /api/overview tells.
  nav.pageError = (msg) => { nav.pageErr = msg || null; if (msg) reload(); paintHealth() }
  window.FactoryNav = nav

  // ---- Sign-in --------------------------------------------------------------------------------
  // A proxy in front of the hub (Authentik forward auth) may answer any request with a redirect
  // to its login page on another origin once the session runs out. fetch and EventSource cannot
  // follow that (CORS), only a top-level navigation can, and while the identity provider's own
  // session is alive it signs back in without a prompt. /api/overview never redirects by itself,
  // so a redirect there means "signed out": reload the page, at most once per 2 min, and only
  // when the tab is visible (a hidden tab reloads when it is looked at again).
  const RELOAD_KEY = 'factory-hub:auth-reload'
  function signedOut() {
    nav.sync.auth = true
    paintHealth()
    if (document.hidden) return
    let last = 0
    try { last = Number(sessionStorage.getItem(RELOAD_KEY)) || 0 } catch { /* storage blocked */ }
    if (Date.now() - last < 120000) return   // just tried: a real login is needed, the banner says so
    try { sessionStorage.setItem(RELOAD_KEY, String(Date.now())) } catch { /* storage blocked */ }
    location.reload()
  }

  async function load() {
    try {
      const res = await fetch(`${ROOT}api/overview`, { cache: 'no-store', redirect: 'manual' })
      if (res.type === 'opaqueredirect' || res.status === 401) return signedOut()
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      nav.data = await res.json()
      nav.sync.at = Date.now()
      nav.sync.err = null
      nav.sync.auth = false
      emit('data', nav.data)
      paintData()
    } catch (err) { nav.sync.err = err.message }
    paintHealth()
  }
  let debounce = null
  const reload = () => { clearTimeout(debounce); debounce = setTimeout(load, 300) }

  // The browser reconnects a dropped stream by itself (after `retry`, 3 s). A blip such as
  // net::ERR_NETWORK_CHANGED (a VPN, Docker adding an interface) is therefore not shown for the
  // first GRACE ms. A reconnect that fails (a redirect to the login page, a 502 while the pod
  // restarts) closes the stream for good: then check the sign-in and open a new one, backing off.
  const GRACE = 10000
  let es = null, esTimer = null, esDelay = 3000
  function connect() {
    if (!('EventSource' in window)) return
    clearTimeout(esTimer)
    if (es) es.close()
    es = new EventSource(`${ROOT}api/stream`)
    es.onopen = () => {
      const was = nav.sync.conn
      nav.sync.conn = 'live'; nav.sync.down = null; esDelay = 3000
      paintHealth()
      if (was === 'error') reload()
    }
    es.onerror = () => {
      if (nav.sync.conn !== 'error') { nav.sync.conn = 'error'; nav.sync.down = Date.now() }
      paintHealth()
      if (es.readyState === EventSource.CLOSED) {
        reload()
        esTimer = setTimeout(connect, esDelay)
        esDelay = Math.min(esDelay * 2, 60000)
      }
    }
    es.addEventListener('job', (ev) => {
      let e; try { e = JSON.parse(ev.data) } catch { return }
      emit('job', e)
      reload()
    })
    es.addEventListener('seen', (ev) => {
      let e; try { e = JSON.parse(ev.data) } catch { return }
      const d = nav.data
      if (!d) return
      const mc = d.machines.find((x) => x.machine === e.machine)
      if (mc) mc.last_seen = e.at
      for (const r of d.repos) if ((r.machines || []).includes(e.machine) && t(e.at) > t(r.last_seen)) r.last_seen = e.at
      nav.sync.at = Date.now()
      emit('seen', e)
      paintHealth()
    })
  }

  const gap = (ms) => {
    const s = Math.max(0, Math.round(ms / 1000))
    return s < 60 ? `${s} s` : s < 3600 ? `${Math.floor(s / 60)} min` : `${Math.floor(s / 3600)} h`
  }
  function health() {
    const { sync } = nav
    const age = sync.at ? Date.now() - sync.at : Infinity
    if (sync.auth) return { s: 'error', label: 'signed out', bar: 'Your sign-in has expired, so nothing on this page updates.', err: true, signIn: true }
    if (!nav.data && !sync.err) return { s: 'wait', label: 'connecting…' }
    if (sync.err && age >= 60000) return { s: 'error', label: `offline ${gap(age)}`, bar: `Can't reach the hub (${sync.err}). Showing data from ${gap(age)} ago.`, err: true }
    if (sync.conn === 'error' && Date.now() - (sync.down || 0) >= GRACE) return { s: 'wait', label: 'reconnecting…', bar: `Live updates are paused, reconnecting. What you see is from ${gap(age)} ago.` }
    if (age >= 60000) return { s: 'wait', label: `stale ${gap(age)}`, bar: `This page has not been refreshed for ${gap(age)}. Numbers may be out of date.` }
    if (nav.pageErr) return { s: 'wait', label: 'reconnecting…', bar: `This view could not be refreshed (${nav.pageErr}). Showing what was loaded before.` }
    if (sync.conn === 'wait') return { s: 'wait', label: 'connecting…' }
    return source()
  }
  // Freshness of the data itself: when a machine last reported, not when this page was drawn.
  function source() {
    const ms = nav.data.machines || []
    if (!ms.length) return { s: 'wait', label: 'no data yet' }
    const ages = ms.map((m) => ({ m: m.machine, age: Date.now() - t(m.last_seen) }))
    const best = Math.min(...ages.map((a) => a.age))
    const stale = ages.filter((a) => a.age > STALE_S * 1000)
    const sec = best / 1000
    if (sec >= 600) {
      const a = ages.reduce((x, y) => (x.age < y.age ? x : y))
      return { s: 'error', label: `stale: ${a.m} ${gap(a.age)}` }
    }
    const base = best < 5000 ? 'data just now' : `data ${gap(best)} ago`
    const extra = stale.length ? ` · ${stale.length === 1 ? stale[0].m : `${stale.length} machines`} stale` : ''
    return { s: sec < 60 && !stale.length ? 'ok' : 'wait', label: base + extra }
  }

  // ---- Chrome -------------------------------------------------------------------------------

  const ICON = {
    mark: '<svg class="nb-logo" viewBox="0 0 32 32" aria-hidden="true"><rect width="32" height="32" rx="7" fill="#20222c"/><path d="M6 25V15l7 4v-4l7 4V8h4v17z" fill="#8be9fd"/></svg>',
    chev: '<svg class="nb-chev" viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 6l4 4 4-4"/></svg>',
    layers: '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" aria-hidden="true"><path d="M8 2l6 3-6 3-6-3z"/><path d="M2 8l6 3 6-3M2 11l6 3 6-3" stroke-linecap="round"/></svg>',
    search: '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" aria-hidden="true"><circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5L14 14"/></svg>',
    check: '<svg class="nb-ck" viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 8.5l3.2 3L13 4.5"/></svg>',
  }

  const CSS = `
html.nav-on body::before { display: none !important; }
.nb-wrap { position: sticky; top: 0; z-index: 20; background: color-mix(in srgb, var(--bg) 92%, transparent); -webkit-backdrop-filter: blur(10px); backdrop-filter: blur(10px); border-bottom: 1px solid var(--line); }
.nb-wrap a, .nb-wrap button, .nb-menu a, .nb-pal button { transition: background-color .18s, border-color .18s, color .18s, box-shadow .18s; }
.nb { display: grid; grid-template-columns: auto auto minmax(0, 1fr) auto auto auto; grid-template-areas: "mark scope tabs search need live"; align-items: center; gap: 0 12px;
  max-width: 1400px; margin: 0 auto; padding: 0 32px; height: 52px; }
.nb-mark { grid-area: mark; display: inline-flex; align-items: center; gap: 9px; height: 44px; font-weight: 600; font-size: 15px; letter-spacing: -.01em; color: var(--text); text-decoration: none; border-radius: 8px; }
.nb-logo { width: 26px; height: 26px; flex: none; }
.nb-scope { grid-area: scope; display: inline-flex; align-items: center; gap: 8px; height: 36px; min-width: 0; max-width: 300px; padding: 0 9px 0 10px; background: var(--panel); color: var(--text);
  border: 1px solid var(--line); border-radius: 8px; font: inherit; font-weight: 600; cursor: pointer; }
.nb-scope:hover, .nb-scope[aria-expanded="true"] { border-color: var(--muted); background: var(--card); }
.nb-scope > svg:first-child { color: var(--muted); flex: none; }
.nb-sl { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.nb-sl .o, .nb-menu .o { font-weight: 400; color: var(--subtle); }
.nb-chev { flex: none; color: var(--muted); transition: transform .18s; }
.nb-scope[aria-expanded="true"] .nb-chev { transform: rotate(180deg); }
.nb-tabs { grid-area: tabs; display: flex; align-items: stretch; align-self: stretch; gap: 2px; margin-left: 6px; min-width: 0; overflow-x: auto; scrollbar-width: none; }
.nb-tabs::-webkit-scrollbar { display: none; }
.nb-tabs a { display: inline-flex; align-items: center; gap: 7px; padding: 0 12px; color: var(--muted); text-decoration: none; white-space: nowrap; font-size: 14px; border-radius: 0; box-shadow: inset 0 -2px 0 transparent; }
.nb-tabs a:hover { color: var(--text); background: color-mix(in srgb, var(--card) 70%, transparent); }
.nb-tabs a[aria-current="page"] { color: var(--text); font-weight: 600; box-shadow: inset 0 -2px 0 var(--active); }
.nb-wrap .sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }
.nb-hint { font-size: 11px; font-weight: 400; color: var(--subtle); border: 1px solid var(--line); border-radius: 999px; padding: 0 7px; line-height: 1.6; }
.nb-search { grid-area: search; display: inline-flex; align-items: center; gap: 8px; height: 36px; padding: 0 8px 0 10px; background: var(--panel); border: 1px solid var(--line); border-radius: 8px; color: var(--muted); font-size: 13px; cursor: pointer; }
.nb-search:hover { color: var(--text); border-color: var(--muted); background: var(--card); }
.nb-search kbd { font: 12px var(--mono); color: var(--muted); background: var(--bg); border: 1px solid var(--line); border-bottom-width: 2px; border-radius: 4px; padding: 0 6px; }
.nb-need { grid-area: need; display: inline-flex; align-items: center; gap: 7px; height: 36px; padding: 0 12px 0 6px; border-radius: 999px; color: var(--human); text-decoration: none; font-size: 13px; font-weight: 600; white-space: nowrap;
  border: 1px solid color-mix(in srgb, var(--human) 55%, var(--line)); background: color-mix(in srgb, var(--human) 12%, var(--bg)); }
.nb-need:hover { background: color-mix(in srgb, var(--human) 22%, var(--bg)); border-color: var(--human); }
.nb-need[hidden] { display: none; }
.nb-n { min-width: 24px; height: 24px; padding: 0 6px; border-radius: 12px; background: var(--human); color: var(--bg); font: 700 12px var(--mono); display: inline-grid; place-items: center; }
.nb-live { grid-area: live; display: inline-flex; align-items: center; gap: 7px; font: 12px var(--mono); color: var(--muted); white-space: nowrap; min-height: 36px; padding: 0 8px; background: none; border: 1px solid transparent; border-radius: 8px; cursor: pointer; }
.nb-live:hover, .nb-live[aria-expanded="true"] { border-color: var(--line); background: var(--panel); color: var(--text); }
.nb-live .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--pass); flex: none; }
.nb-live.wait { color: var(--changes); } .nb-live.wait .dot { background: var(--changes); }
.nb-live.error { color: var(--human); } .nb-live.error .dot { background: var(--human); }
.nb-banner { padding: 5px 32px; font: 12px/1.6 var(--mono); text-align: center; color: var(--changes); background: color-mix(in srgb, var(--changes) 14%, var(--bg)); border-top: 1px solid color-mix(in srgb, var(--changes) 45%, var(--line)); }
.nb-banner.err { color: var(--human); background: color-mix(in srgb, var(--human) 12%, var(--bg)); border-top-color: color-mix(in srgb, var(--human) 45%, var(--line)); }
.nb-banner[hidden] { display: none; }
.nb-banner a { color: inherit; font-weight: 600; text-decoration: underline; text-underline-offset: 2px; }
.nb-crumb { max-width: 1400px; margin: 0 auto; padding: 22px 32px 2px; }
.nb-crumb h1 { margin: 0; font-size: 18px; font-weight: 600; letter-spacing: -.01em; line-height: 1.35; overflow-wrap: anywhere; }
.nb-crumb h1 .o { font-weight: 400; color: var(--subtle); }
.nb-crumb h1 .sep { color: var(--subtle); font-weight: 400; margin: 0 .35em; }
.nb-crumb h1 .v { color: var(--muted); font-weight: 500; }
.nb-crumb p { margin: 2px 0 0; min-height: 22px; font: 12px var(--mono); color: var(--muted); }
.nb-wrap :focus-visible, .nb-menu :focus-visible, .nb-mach :focus-visible, .nb-pal :focus-visible { outline: 2px solid var(--active); outline-offset: 2px; }
.nb-tabs a:focus-visible { outline-offset: -3px; border-radius: 6px; }

/* Scope popover */
.nb-menu { position: fixed; inset: auto; margin: 0; padding: 6px; width: min(460px, calc(100vw - 16px)); max-height: 70vh; overflow-y: auto; overscroll-behavior: contain; border: 1px solid var(--line); border-radius: 12px; background: var(--panel); color: var(--text); box-shadow: 0 18px 48px rgba(0, 0, 0, .55); }
.nb-menu h2 { margin: 6px 10px 4px; font: 500 12px var(--mono); letter-spacing: .06em; text-transform: uppercase; color: var(--subtle); }
.nb-menu ul { list-style: none; margin: 0; padding: 0; }
.nb-menu hr { border: 0; border-top: 1px solid var(--line); margin: 6px 4px; }
.nb-it { display: grid; grid-template-columns: 8px minmax(0, 1fr) auto 14px; gap: 10px; align-items: center; min-height: 44px; padding: 6px 10px; border-radius: 8px; color: var(--text); text-decoration: none; font-size: 14px; }
.nb-it:hover { background: var(--card); }
.nb-it[aria-current="page"] { background: var(--card-hover); box-shadow: inset 2px 0 0 var(--active); }
.nb-it .nm { min-width: 0; overflow-wrap: anywhere; line-height: 1.3; }
.nb-it .c { white-space: nowrap; display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 0 10px; font: 12px var(--mono); color: var(--muted); }
.nb-it .c .run { color: var(--active); } .nb-it .c .att { color: var(--human); }
.nb-it .ck { color: var(--active); }
.nb-it .fd { width: 8px; height: 8px; border-radius: 50%; background: var(--faint); }
.nb-it .fd.ok { background: var(--pass); } .nb-it .fd.warn { background: var(--changes); } .nb-it .fd.bad { background: var(--human); }
.nb-menu .note { padding: 10px; color: var(--subtle); font-size: 13px; }

/* Machines popover: opens from the freshness indicator */
.nb-mach { position: fixed; inset: auto; margin: 0; padding: 8px; width: min(400px, calc(100vw - 16px)); max-height: 70vh; overflow-y: auto; border: 1px solid var(--line); border-radius: 12px; background: var(--panel); color: var(--text); box-shadow: 0 18px 48px rgba(0, 0, 0, .55); }
.nb-mach h2 { margin: 4px 6px 6px; font: 500 12px var(--mono); letter-spacing: .06em; text-transform: uppercase; color: var(--subtle); }
.nb-mach ul { list-style: none; margin: 0; padding: 0; }
.nb-mc { display: grid; grid-template-columns: 8px minmax(0, 1fr) auto; gap: 2px 10px; align-items: baseline; padding: 8px 6px; border-radius: 8px; }
.nb-mc + .nb-mc { border-top: 1px solid var(--line); }
.nb-mc .fd { width: 8px; height: 8px; border-radius: 50%; background: var(--faint); align-self: center; }
.nb-mc .fd.ok { background: var(--pass); } .nb-mc .fd.warn { background: var(--changes); } .nb-mc .fd.bad { background: var(--human); }
.nb-mc .nm { font-weight: 600; overflow-wrap: anywhere; }
.nb-mc .when { font: 12px var(--mono); color: var(--muted); white-space: nowrap; }
.nb-mc .when.warn { color: var(--changes); } .nb-mc .when.bad { color: var(--human); }
.nb-mc .rp { grid-column: 2 / -1; font: 12px var(--mono); color: var(--subtle); overflow-wrap: anywhere; }
.nb-mach .note { margin: 6px 6px 2px; padding-top: 8px; border-top: 1px solid var(--line); font: 12px/1.5 var(--mono); color: var(--subtle); }

/* Palette */
dialog.nb-pal { padding: 0; border: 1px solid var(--line); border-radius: 12px; background: var(--panel); color: var(--text); width: min(640px, calc(100vw - 24px));
  max-width: none; margin: 12vh auto auto; box-shadow: 0 24px 64px rgba(0, 0, 0, .6); }
dialog.nb-pal::backdrop { background: rgba(5, 6, 10, .6); overflow: hidden; overscroll-behavior: contain; }
.nb-pal .in { display: flex; flex-direction: column; max-height: min(520px, 76vh); }
#nb-pal-q { background: none; border: 0; border-bottom: 1px solid var(--line); color: var(--text); font: 16px/1.4 inherit; padding: 16px 18px; outline: none; width: 100%; border-radius: 12px 12px 0 0; }
#nb-pal-q::placeholder { color: var(--subtle); }
#nb-pal-q:focus { border-bottom-color: var(--active); }
#nb-pal-list { list-style: none; margin: 0; padding: 6px; overflow-y: auto; min-height: 0; }
#nb-pal-list li { display: grid; grid-template-columns: 48px minmax(0, 1fr); gap: 10px; align-items: center; padding: 8px 10px; border-radius: 8px; cursor: pointer; min-height: 44px; }
#nb-pal-list li:hover { background: var(--card); }
#nb-pal-list li[aria-selected="true"] { background: var(--card-hover); box-shadow: inset 2px 0 0 var(--active); }
#nb-pal-list .kind { font: 12px var(--mono); color: var(--subtle); text-transform: uppercase; letter-spacing: .04em; }
#nb-pal-list .lbl { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 14px; }
#nb-pal-list .sub { display: block; font: 12px var(--mono); color: var(--subtle); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
#nb-pal-list mark { background: none; color: var(--active); font-weight: 600; }
.nb-pal .empty { padding: 18px; color: var(--subtle); font-size: 13px; }
.nb-pal .foot { display: flex; gap: 14px; flex-wrap: wrap; padding: 8px 14px; border-top: 1px solid var(--line); font: 12px var(--mono); color: var(--subtle); }
.nb-pal .foot span:last-child { margin-left: auto; }
.nb-pal kbd { font: 12px var(--mono); color: var(--muted); background: var(--bg); border: 1px solid var(--line); border-bottom-width: 2px; border-radius: 4px; padding: 0 6px; }

@media (max-width: 1000px) {
  .nb-search .l, .nb-search kbd { display: none; }
  .nb-search { padding: 0 10px; }
}
@media (max-width: 860px) {
  .nb-need .l { display: none; }
  .nb-need { padding: 0 6px; }
}
/* Two rows: the controls, then the views as a segmented control that scrolls sideways on its own. */
@media (max-width: 720px) {
  .nb { grid-template-columns: auto minmax(0, 1fr) auto auto auto; grid-template-areas: "mark scope search need live" "tabs tabs tabs tabs tabs"; height: auto; padding: 0 12px; gap: 0 8px; }
  .nb-banner, .nb-crumb { padding-left: 16px; padding-right: 16px; }
  .nb-mark { height: 48px; } .nb-mark span { display: none; }
  .nb-scope { height: 44px; max-width: none; justify-self: start; }
  .nb-scope .o { display: none; }
  .nb-search, .nb-need { height: 44px; min-width: 44px; justify-content: center; }
  .nb-live { min-width: 44px; min-height: 44px; justify-content: center; padding: 0 6px; }
  .nb-live #nb-lt { display: none; }
  .nb-tabs { margin: 2px 0 8px; padding: 2px; gap: 2px; align-self: auto; background: var(--panel); border: 1px solid var(--line); border-radius: 12px; }
  .nb-tabs a { min-height: 44px; padding: 0 16px; border-radius: 9px; box-shadow: none; flex: 1 0 auto; justify-content: center; }
  .nb-tabs a[aria-current="page"] { background: var(--card-hover); box-shadow: inset 0 0 0 1px var(--muted); }
  .nb-tabs a:focus-visible { outline-offset: -2px; }
  .nb-crumb { padding-top: 16px; }
  dialog.nb-pal { margin-top: 8vh; }
  .nb-pal .hide-s { display: none; }
  #nb-pal-list li { min-height: 48px; }
}
@media (max-width: 520px) { .nb-hint { display: none; } }
@media (prefers-reduced-motion: reduce) {
  .nb-wrap *, .nb-menu *, .nb-pal * { transition-duration: .01ms !important; }
}
`

  let els = null
  function mount() {
    const style = document.createElement('style')
    style.id = 'nb-css'
    style.textContent = CSS
    document.head.append(style)

    const wrap = document.createElement('div')
    wrap.className = 'nb-wrap'
    wrap.innerHTML = `<header class="nb">
      <a class="nb-mark" href="${ROOT}" aria-label="Factory, all repos overview">${ICON.mark}<span>Factory</span></a>
      <button type="button" class="nb-scope" id="nb-scope" popovertarget="nb-menu" aria-controls="nb-menu" aria-expanded="false" aria-label="Scope">${ICON.layers}<span class="nb-sl" id="nb-sl"></span>${ICON.chev}</button>
      <nav class="nb-tabs" id="nb-tabs" aria-label="Views">${tabs.map(([v, h]) => `<a href="${esc(h)}" data-v="${v}">${VIEWS[v]}${v === 'plan' && at.scope === 'repo' ? '<small class="nb-hint">all repos</small>' : ''}</a>`).join('')}</nav>
      <button type="button" class="nb-search" id="nb-open" aria-keyshortcuts="/ Control+K Meta+K" aria-label="Search repos, jobs and views">${ICON.search}<span class="l">Search</span><kbd>/</kbd></button>
      <a class="nb-need" id="nb-need" href="${ROOT}#needs-you" hidden><span class="nb-n" id="nb-nn">0</span><span class="l">needs you</span></a>
      <button type="button" class="nb-live wait" id="nb-live" popovertarget="nb-mach" aria-controls="nb-mach" aria-expanded="false"><span class="dot" aria-hidden="true"></span><span id="nb-lt">connecting…</span></button>
      <span class="sr" id="nb-ls" role="status"></span>
    </header>
    <div class="nb-banner" id="nb-banner" role="status" hidden></div>`
    document.body.prepend(wrap)

    const menu = document.createElement('div')
    menu.className = 'nb-menu'
    menu.id = 'nb-menu'
    menu.setAttribute('popover', 'auto')
    menu.setAttribute('aria-label', 'Choose a repo or all repos')
    wrap.after(menu)

    const crumb = document.createElement('div')
    crumb.className = 'nb-crumb'
    crumb.innerHTML = '<h1 id="nb-h1"></h1><p id="nb-sub"></p>'
    menu.after(crumb)

    const pal = document.createElement('dialog')
    pal.className = 'nb-pal'
    pal.id = 'nb-pal'
    pal.setAttribute('aria-label', 'Search repos, jobs and views')
    pal.setAttribute('closedby', 'any')
    pal.innerHTML = `<div class="in">
      <input id="nb-pal-q" type="text" role="combobox" aria-expanded="true" aria-controls="nb-pal-list" aria-autocomplete="list" aria-activedescendant=""
        aria-label="Search repos, jobs and views" placeholder="Search: repo, job, #number, or “costs nerdround”" autocomplete="off" spellcheck="false">
      <ul id="nb-pal-list" role="listbox" aria-label="Results"></ul>
      <div class="foot"><span><kbd>↑</kbd> <kbd>↓</kbd> move</span><span><kbd>↵</kbd> open</span><span class="hide-s"><kbd>esc</kbd> close</span><span id="nb-pal-n" aria-live="polite"></span></div></div>`
    crumb.after(pal)

    const mach = document.createElement('div')
    mach.className = 'nb-mach'
    mach.id = 'nb-mach'
    mach.setAttribute('popover', 'auto')
    mach.setAttribute('aria-label', 'Machines and data freshness')
    wrap.after(mach)

    document.documentElement.classList.add('nav-on')
    els = {
      wrap, menu, crumb, pal, scope: $('#nb-scope'), sl: $('#nb-sl'), tabs: $('#nb-tabs'), need: $('#nb-need'), nn: $('#nb-nn'),
      live: $('#nb-live'), lt: $('#nb-lt'), ls: $('#nb-ls'), mach, banner: $('#nb-banner'), h1: $('#nb-h1'),
    }
  }

  // ---- Paint --------------------------------------------------------------------------------

  function paintHealth() {
    if (!els) return
    const h = health()
    const cls = `nb-live ${h.s === 'ok' ? '' : h.s === 'error' ? 'error' : 'wait'}`.trim()
    if (els.live.className !== cls) els.live.className = cls
    if (els.lt.textContent !== h.label) els.lt.textContent = h.label
    const al = `Data freshness: ${h.label}. Show machines`
    if (els.live.getAttribute('aria-label') !== al) els.live.setAttribute('aria-label', al)
    // Screen readers hear a change of state, not the ticking seconds.
    const st = `${h.s}|${h.label.replace(/\d+ ?(s|min|h)\b/g, '#')}`
    if (els.ls.dataset.k !== st) { els.ls.dataset.k = st; els.ls.textContent = h.label }
    if (els.mach.matches(':popover-open')) paintMachines()
    els.banner.hidden = !h.bar
    const key = h.bar ? `${h.bar}|${!!h.signIn}` : ''
    if (h.bar && els.banner.dataset.k !== key) {
      els.banner.dataset.k = key
      els.banner.textContent = h.bar
      if (h.signIn) {
        const a = document.createElement('a')
        a.href = location.href
        a.textContent = 'Sign in again'
        els.banner.append(' ', a)
      }
    }
    els.banner.classList.toggle('err', !!h.err)
  }

  function setFavicon(n) {
    const link = $('link[rel~="icon"]')
    if (!link) return
    const badge = n > 0 ? '<circle cx="24" cy="8" r="7.5" fill="#ff5555" stroke="#14151b" stroke-width="2"/>' : ''
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="7" fill="#20222c"/><path d="M6 25V15l7 4v-4l7 4V8h4v17z" fill="#8be9fd"/>${badge}</svg>`
    const url = `data:image/svg+xml,${encodeURIComponent(svg)}`
    if (link.getAttribute('href') !== url) link.setAttribute('href', url)
  }

  function paintScope() {
    const html = at.scope === 'all' ? 'All repos' : `<span class="o">${esc(ownerOf(at.repo))}</span>${esc(rshort(at.repo))}`
    if (els.sl.innerHTML !== html) els.sl.innerHTML = html
    els.scope.title = at.scope === 'all' ? 'Scope: all repos. Switch repo' : `Scope: ${at.repo}. Switch repo`
    els.scope.setAttribute('aria-label', `Scope: ${at.scope === 'all' ? 'all repos' : at.repo}. Switch repo or view all`)
  }

  function paintView() {
    const v = viewNow()
    for (const a of els.tabs.children) {
      if (a.dataset.v === v) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current')
    }
    const needs = nav.data ? nav.data.needs_you.length : 0
    const label = VIEWS[v]
    els.h1.innerHTML = at.page === 'overview' ? label
      : `${at.scope === 'all' ? 'All repos' : `<span class="o">${esc(ownerOf(at.repo))}</span>${esc(rshort(at.repo))}`}<span class="sep" aria-hidden="true">·</span><span class="v">${label}</span>`
    document.title = `${needs ? `(${needs}) ` : ''}${at.page === 'overview' ? 'Overview' : `${label} · ${scopeLabel()}`} · Factory`
  }

  function paintData() {
    if (!els) return
    const needs = nav.data ? nav.data.needs_you.length : 0
    els.need.hidden = !needs
    if (els.nn.textContent !== String(needs)) els.nn.textContent = needs
    els.need.setAttribute('aria-label', `${plural(needs, 'job')} waiting on you, across all repos. Show them`)
    setFavicon(needs)
    paintView()
  }

  // ---- Machines popover ---------------------------------------------------------------------

  function paintMachines() {
    const d = nav.data
    if (!d) { els.mach.innerHTML = '<div class="note">Waiting for the hub…</div>'; return }
    const ago = (iso) => { const s = Date.now() - t(iso); return s < 5000 ? 'just now' : `${gap(s)} ago` }
    const rows = [...d.machines].sort((a, b) => t(b.last_seen) - t(a.last_seen)).map((m) => {
      const c = freshCls(m.last_seen)
      const rs = d.repos.filter((r) => (r.machines || []).includes(m.machine)).map((r) => rshort(r.repo))
      return `<li class="nb-mc"><span class="fd ${c}" aria-hidden="true"></span><span class="nm">${esc(m.machine)}</span><span class="when ${c}">${c === 'bad' ? 'stale · ' : ''}seen ${ago(m.last_seen)}</span><span class="rp">${plural(m.repos, 'repo')}${rs.length ? `: ${esc(rs.join(', '))}` : ''}</span></li>`
    }).join('')
    const page = nav.sync.at ? `Page refreshed ${ago(new Date(nav.sync.at).toISOString())}` : 'Page not refreshed yet'
    const html = `<h2>Machines · ${d.machines.length}</h2><ul>${rows || '<li class="note">No machine has reported.</li>'}</ul>
      <p class="note">${page}. Live updates ${nav.sync.conn === 'live' ? 'connected' : 'not connected'}. A machine is stale after ${STALE_S / 60} min of silence.</p>`
    if (els.mach.innerHTML !== html) els.mach.innerHTML = html
  }
  function placeMach() {
    const r = els.live.getBoundingClientRect()
    const w = Math.min(400, innerWidth - 16)
    els.mach.style.left = `${Math.max(8, Math.min(r.right - w, innerWidth - w - 8))}px`
    els.mach.style.top = `${r.bottom + 6}px`
    els.mach.style.maxHeight = `${Math.max(160, innerHeight - r.bottom - 18)}px`
  }

  // ---- Scope menu ---------------------------------------------------------------------------

  const freshCls = (iso) => { const s = (Date.now() - t(iso)) / 1000; return s < 60 ? 'ok' : s < 600 ? 'warn' : 'bad' }
  const rank = (r) => [r.counts?.needs_you ? 1 : 0, r.counts?.running ? 1 : 0]
  // Switching scope keeps the view where the new scope has it.
  const hrefIn = (scope) => href(scope, scope !== 'all' && viewNow() === 'plan' ? 'board' : viewNow())

  function counts(c) {
    const out = []
    if (c.running) out.push(`<span class="run">${c.running} running</span>`)
    if (c.needs_you) out.push(`<span class="att">${c.needs_you} needs you</span>`)
    if (!out.length) out.push(`<span>${c.total ? 'idle' : 'no jobs'}</span>`)
    return out.join('')
  }
  function buildMenu() {
    const d = nav.data
    const cur = (on) => (on ? ' aria-current="page" autofocus' : '')
    const one = (h, name, fresh, c, on) => `<li><a class="nb-it" href="${esc(h)}"${cur(on)}><span class="fd ${fresh}" aria-hidden="true"></span><span class="nm">${name}</span><span class="c">${counts(c)}</span><span class="ck">${on ? ICON.check : ''}</span></a></li>`
    if (!d) { els.menu.innerHTML = '<div class="note">Loading repos…</div>'; return }
    const tot = d.repos.reduce((a, r) => ({ running: a.running + (r.counts?.running || 0), needs_you: a.needs_you + (r.counts?.needs_you || 0), total: a.total + (r.counts?.total || 0) }), { running: 0, needs_you: 0, total: 0 })
    const newest = d.repos.map((r) => r.last_seen).sort().pop()
    const repos = [...d.repos].sort((a, b) => { const x = rank(a), y = rank(b); return y[0] - x[0] || y[1] - x[1] || a.repo.localeCompare(b.repo) })
    els.menu.innerHTML = `<h2>Scope</h2><ul>${one(hrefIn('all'), 'All repos', newest ? freshCls(newest) : '', tot, at.scope === 'all')}</ul><hr>
      <h2>Repos · ${d.repos.length}</h2><ul>${repos.map((r) => {
        const [o, ...n] = String(r.repo).split('/')
        return one(hrefIn(r.repo), n.length ? `<span class="o">${esc(o)}/</span>${esc(n.join('/'))}` : esc(o), freshCls(r.last_seen), r.counts || {}, at.scope === 'repo' && r.repo === at.repo)
      }).join('')}</ul>`
    // A repo page opened by a link before the overview knows it still gets its row marked.
  }
  function placeMenu() {
    const r = els.scope.getBoundingClientRect()
    const w = Math.min(460, innerWidth - 16)
    els.menu.style.left = `${Math.max(8, Math.min(r.left, innerWidth - w - 8))}px`
    els.menu.style.top = `${r.bottom + 6}px`
    els.menu.style.maxHeight = `${Math.max(160, innerHeight - r.bottom - 18)}px`
  }

  // ---- Palette (/ or Ctrl/Cmd+K) ------------------------------------------------------------

  const pal = { items: [], shown: [], at: 0 }
  const numOf = (id) => String(id).split('~').pop().split('-')[0]
  const refOf = (e) => (e.job.issue ? `#${e.job.issue}` : `#${numOf(e.id)}`)
  function palItems() {
    const d = nav.data
    if (!d) return []
    const items = []
    const V = [['board', 'Board'], ['costs', 'Costs']]
    items.push({ kind: 'view', label: 'Overview', sub: 'All repos', href: ROOT, hay: 'overview all repos', rank: at.page === 'overview' ? 0.4 : 0.6 })
    for (const [v, l] of V) items.push({ kind: 'view', label: `${l}: All repos`, sub: 'every repo together', href: href('all', v), hay: `${l} all repos`, rank: at.scope === 'all' ? 0.5 : -1 })
    items.push({ kind: 'view', label: 'Subscription', sub: 'API-equivalent vs what you pay, all repos', href: href('all', 'plan'), hay: 'subscription plan fees all repos', rank: at.scope === 'all' ? 0.5 : -1 })
    for (const r of d.repos) {
      const c = r.counts || {}
      const rk = (c.needs_you ? 2 : 0) + (c.running ? 1 : 0)
      items.push({ kind: 'repo', label: r.repo, sub: `${c.running || 0} running · ${c.needs_you || 0} needs you · ${c.total || 0} jobs`, href: hrefIn(r.repo), hay: r.repo, rank: rk })
      for (const [v, l] of V) items.push({ kind: 'view', label: `${l}: ${rshort(r.repo)}`, sub: r.repo, href: href(r.repo, v), hay: `${l} ${r.repo}`, rank: at.scope === 'repo' && at.repo === r.repo ? 0.5 : -1 })
    }
    const jobs = new Map()
    for (const [list, rk] of [[d.needs_you, 3], [d.live, 2], [d.recent, 0]]) {
      for (const e of list) {
        const k = `${e.repo}|${e.id}`
        if (!jobs.has(k)) jobs.set(k, { kind: 'job', label: `${refOf(e)} ${e.job.title}`, sub: `${e.repo} · ${e.job.stage}`, href: e.href, hay: `${e.repo} ${e.id} ${refOf(e)} #${numOf(e.id)} ${e.job.title}`, rank: rk })
      }
    }
    return [...items, ...jobs.values()].filter((x) => safe(x.href))
  }
  // Every word of the query must match: as a substring (best) or as scattered letters.
  function fuzzy(q, hay) {
    hay = hay.toLowerCase()
    let score = 0
    for (const tok of q.toLowerCase().split(/\s+/).filter(Boolean)) {
      const i = hay.indexOf(tok)
      if (i >= 0) { score += 100 - Math.min(i, 60) + (i === 0 || /[\s/#_:-]/.test(hay[i - 1]) ? 30 : 0); continue }
      let p = -1, last = -1, holes = 0
      for (const ch of tok) { p = hay.indexOf(ch, p + 1); if (p < 0) return -1; if (last >= 0) holes += p - last - 1; last = p }
      if (tok.length < 3 || holes > 3) return -1
      score += Math.max(1, 40 - holes)
    }
    return score
  }
  const mark = (s, q) => {
    const tok = q.toLowerCase().split(/\s+/).filter(Boolean)
    const lo = s.toLowerCase()
    const hit = new Array(s.length).fill(false)
    for (const k of tok) { const i = lo.indexOf(k); if (i >= 0) for (let c = i; c < i + k.length; c++) hit[c] = true }
    let out = '', open = false
    for (let c = 0; c < s.length; c++) {
      if (hit[c] !== open) { out += hit[c] ? '<mark>' : '</mark>'; open = hit[c] }
      out += esc(s[c])
    }
    return out + (open ? '</mark>' : '')
  }
  function palRender() {
    const q = $('#nb-pal-q').value.trim()
    pal.shown = (q
      ? pal.items.map((x) => ({ x, s: fuzzy(q, x.hay) })).filter((r) => r.s >= 0).sort((a, b) => b.s - a.s || b.x.rank - a.x.rank).map((r) => r.x)
      : pal.items.filter((x) => x.rank >= 0).sort((a, b) => b.rank - a.rank)).slice(0, q ? 30 : 12)
    pal.at = Math.min(pal.at, Math.max(0, pal.shown.length - 1))
    $('#nb-pal-list').innerHTML = pal.shown.length ? pal.shown.map((x, i) => `<li role="option" id="nb-opt-${i}" data-i="${i}" aria-selected="${i === pal.at}">
        <span class="kind">${x.kind}</span><span><span class="lbl">${mark(x.label, q)}</span><span class="sub">${esc(x.sub)}</span></span></li>`).join('')
      : `<li class="empty" role="presentation">${nav.data ? 'Nothing matches.' : 'Still loading…'}</li>`
    $('#nb-pal-q').setAttribute('aria-activedescendant', pal.shown.length ? `nb-opt-${pal.at}` : '')
    $('#nb-pal-n').textContent = pal.shown.length ? plural(pal.shown.length, 'result') : 'no results'
  }
  function palMove(by) {
    if (!pal.shown.length) return
    pal.at = (pal.at + by + pal.shown.length) % pal.shown.length
    for (const li of $('#nb-pal-list').children) li.setAttribute('aria-selected', String(li.dataset.i === String(pal.at)))
    $('#nb-pal-q').setAttribute('aria-activedescendant', `nb-opt-${pal.at}`)
    $(`#nb-opt-${pal.at}`).scrollIntoView({ block: 'nearest' })
  }
  function palGo(i) { const x = pal.shown[i]; if (x) { els.pal.close(); location.href = x.href } }
  function palOpen() {
    if (els.pal.open) return
    pal.items = palItems(); pal.at = 0
    $('#nb-pal-q').value = ''
    palRender()
    els.pal.showModal()
  }
  nav.openSearch = palOpen

  function wire() {
    $('#nb-open').addEventListener('click', palOpen)
    const q = $('#nb-pal-q'), list = $('#nb-pal-list')
    q.addEventListener('input', () => { pal.at = 0; palRender() })
    q.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowDown') { e.preventDefault(); palMove(1) }
      else if (e.key === 'ArrowUp') { e.preventDefault(); palMove(-1) }
      else if (e.key === 'Enter') { e.preventDefault(); palGo(pal.at) }
    })
    list.addEventListener('click', (e) => { const li = e.target.closest('li[data-i]'); if (li) palGo(Number(li.dataset.i)) })
    list.addEventListener('pointermove', (e) => { const li = e.target.closest('li[data-i]'); if (li && Number(li.dataset.i) !== pal.at) palMove(Number(li.dataset.i) - pal.at) })
    // Safari has no closedby="any": a click on the backdrop reports the dialog itself.
    els.pal.addEventListener('click', (e) => { if (e.target === els.pal) els.pal.close() })
    document.addEventListener('keydown', (e) => {
      const typing = e.target.closest?.('input, textarea, select, [contenteditable]')
      if (((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') || (e.key === '/' && !typing && !e.ctrlKey && !e.metaKey && !e.altKey)) {
        e.preventDefault(); palOpen()
      }
    })

    // Scope menu: links in tab order, plus the arrow keys for a long list.
    els.menu.addEventListener('beforetoggle', (e) => { if (e.newState === 'open') { buildMenu(); placeMenu() } })
    els.menu.addEventListener('toggle', (e) => els.scope.setAttribute('aria-expanded', String(e.newState === 'open')))
    els.menu.addEventListener('click', (e) => { if (e.target.closest('a')) els.menu.hidePopover() })
    els.menu.addEventListener('keydown', (e) => {
      const items = [...els.menu.querySelectorAll('a')]
      const i = items.indexOf(document.activeElement)
      const to = e.key === 'ArrowDown' ? i + 1 : e.key === 'ArrowUp' ? i - 1 : e.key === 'Home' ? 0 : e.key === 'End' ? items.length - 1 : null
      if (to === null || !items.length) return
      e.preventDefault()
      items[(to + items.length) % items.length].focus()
    })
    els.mach.addEventListener('beforetoggle', (e) => { if (e.newState === 'open') { paintMachines(); placeMach() } })
    els.mach.addEventListener('toggle', (e) => els.live.setAttribute('aria-expanded', String(e.newState === 'open')))
    addEventListener('resize', () => { if (els.menu.matches(':popover-open')) placeMenu(); if (els.mach.matches(':popover-open')) placeMach() })

    // The needs-you badge on the overview scrolls to the section instead of reloading the page.
    els.need.addEventListener('click', (e) => {
      if (at.page !== 'overview' || e.metaKey || e.ctrlKey || e.shiftKey || e.button) return
      e.preventDefault()
      history.pushState(null, '', `${ROOT}#needs-you`)
      dispatchEvent(new PopStateEvent('popstate'))
    })
    addEventListener('hashchange', () => { redirectPlan(); paintView() })
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) return
      load()
      if (es && es.readyState === EventSource.CLOSED) connect()
    })
  }

  try {
    mount()
    paintScope()
    paintView()
    wire()
    paintHealth()
    load()
    connect()
    setInterval(load, 30000)
    setInterval(paintHealth, 1000)
  } catch (err) {
    console.error('nav.js could not mount', err)
    nav.fail = true
  }
})()
