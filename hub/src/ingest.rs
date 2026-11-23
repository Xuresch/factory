//! POST /api/ingest: validate a reporter's payload and apply it in one transaction.
//!
//! Reads what the hub holds, decides, then writes everything in one batch, so a
//! bad payload leaves nothing behind. Ids are allocated here (ingests run one at
//! a time), so every row of the batch can name its parent.
//!
//! Nothing a machine reported is deleted when it disappears from the machine:
//! a job or checkout gets `removed_at` and stays in the history. Only files the
//! reporter says are gone, and tickets on a full push, are deleted.

use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

use serde_json::{json, Map, Value};

use crate::project::{first_line, project, Projection, Seen, JOB_COLUMNS};
use crate::store::{self, get_int, get_or_empty, int, opt, real, text, Param, Statement};
use crate::util::{doc_hash, now_iso, safe_path, truthy, valid_repo};
use crate::Hub;

pub enum IngestError {
    /// The body is not what the contract describes (400).
    Bad(String),
    Db(store::Error),
}

impl From<store::Error> for IngestError {
    fn from(e: store::Error) -> Self {
        IngestError::Db(e)
    }
}

fn bad<T>(message: &str) -> Result<T, IngestError> {
    Err(IngestError::Bad(message.to_owned()))
}

fn expect(ok: bool, message: &str) -> Result<(), IngestError> {
    if ok {
        Ok(())
    } else {
        bad(message)
    }
}

/// What an ingest did, for the reply and the log line.
pub struct Outcome {
    pub machine: String,
    pub need_full: bool,
    pub changed: usize,
    pub repos: Vec<String>,
}

struct Event {
    at: String,
    machine: String,
    repo: String,
    job: String,
    title: String,
    from: Option<String>,
    to: Option<String>,
}

impl Event {
    fn to_json(&self) -> Value {
        json!({"at": self.at, "machine": self.machine, "repo": self.repo, "job": self.job,
               "title": self.title, "from": self.from, "to": self.to})
    }
}

/// A list that may be absent or empty (`x or []`); anything else non-list is bad.
fn list_of<'a>(v: Option<&'a Value>, message: &str) -> Result<&'a [Value], IngestError> {
    match v {
        None => Ok(&[]),
        Some(Value::Array(a)) => Ok(a),
        Some(v) if !truthy(v) => Ok(&[]),
        Some(_) => bad(message),
    }
}

/// An object that may be absent or empty (`x or {}`); anything else non-object is bad.
fn map_of<'a>(
    v: Option<&'a Value>,
    message: &str,
) -> Result<Option<&'a Map<String, Value>>, IngestError> {
    match v {
        None => Ok(None),
        Some(Value::Object(o)) => Ok(Some(o)),
        Some(v) if !truthy(v) => Ok(None),
        Some(_) => bad(message),
    }
}

/// `INSERT … ON CONFLICT(id) DO UPDATE` over every jobs column but the keys.
pub static UPSERT_JOB: LazyLock<String> = LazyLock::new(|| {
    let cols: Vec<&str> = ["doc", "doc_hash"].into_iter().chain(JOB_COLUMNS).collect();
    let marks = vec!["?"; cols.len() + 3].join(",");
    let set: Vec<String> = cols.iter().map(|c| format!("{c}=excluded.{c}")).collect();
    format!(
        "INSERT INTO jobs (id, checkout_id, job_key, {}) VALUES ({marks}) \
         ON CONFLICT(id) DO UPDATE SET {}",
        cols.join(", "),
        set.join(", ")
    )
});

pub fn upsert_job(
    id: i64,
    checkout_id: i64,
    key: &str,
    doc: &str,
    hash: &str,
    p: &Projection,
) -> Statement {
    let mut params = vec![int(id), int(checkout_id), text(key), text(doc), text(hash)];
    params.extend(p.columns.iter().cloned());
    (UPSERT_JOB.as_str(), params)
}

/// Ids for new rows; ingests run one at a time, so MAX(id)+1 stays free.
#[derive(Default)]
struct Ids(HashMap<&'static str, i64>);

impl Ids {
    async fn next(
        &mut self,
        store: &store::Store,
        table: &'static str,
    ) -> Result<i64, IngestError> {
        if !self.0.contains_key(table) {
            let sql = match table {
                "machines" => "SELECT COALESCE(MAX(id), 0) AS n FROM machines",
                "repos" => "SELECT COALESCE(MAX(id), 0) AS n FROM repos",
                "checkouts" => "SELECT COALESCE(MAX(id), 0) AS n FROM checkouts",
                _ => "SELECT COALESCE(MAX(id), 0) AS n FROM jobs",
            };
            let rows = store.query(sql, vec![]).await?;
            let max = rows.first().and_then(|r| get_int(r, "n")).unwrap_or(0);
            self.0.insert(table, max);
        }
        let n = self.0.entry(table).or_default();
        *n += 1;
        Ok(*n)
    }
}

/// One `id` column of the first row.
async fn id_of(
    store: &store::Store,
    sql: &str,
    params: Vec<Param>,
) -> Result<Option<i64>, IngestError> {
    Ok(store
        .query(sql, params)
        .await?
        .first()
        .and_then(|r| get_int(r, "id")))
}

/// A job of a checkout as the hub holds it.
struct Held {
    id: i64,
    hash: String,
    stage: Option<String>,
    first_seen: String,
    removed: bool,
}

/// The statements replacing a machine's subscriptions.
fn subscription_statements(machine_id: i64, subs: &Value) -> Vec<Statement> {
    let mut out: Vec<Statement> = vec![(
        "DELETE FROM subscriptions WHERE machine_id=?",
        vec![int(machine_id)],
    )];
    for (n, sub) in subs.as_array().into_iter().flatten().enumerate() {
        let Some(sub) = sub.as_object() else { continue };
        out.push((
            "INSERT INTO subscriptions (machine_id, seq, name, agent, usd_per_month, since) VALUES (?,?,?,?,?,?)",
            vec![
                int(machine_id),
                int(n as i64),
                text(sub.get("name").and_then(Value::as_str).unwrap_or("")),
                opt(sub.get("agent").and_then(Value::as_str)),
                real(crate::util::number(sub.get("usd_per_month"))),
                opt(sub.get("since").and_then(Value::as_str)
                    .filter(|key| crate::subscriptions::month_start(key).is_some())),
            ],
        ));
    }
    out
}

/// The statements replacing a machine's outside-usage scan.
fn outside_statements(machine_id: i64, outside: &Value, now: &str) -> Vec<Statement> {
    let doc = outside.to_string();
    let m = |id: i64| vec![int(id)];
    let mut out: Vec<Statement> = vec![
        ("DELETE FROM outside_months WHERE machine_id=?", m(machine_id)),
        ("DELETE FROM outside_unpriced WHERE machine_id=?", m(machine_id)),
        ("DELETE FROM outside_cwds WHERE machine_id=?", m(machine_id)),
        (
            "INSERT INTO outside_scans (machine_id, status, factory_sessions, doc, doc_hash, received_at) \
             VALUES (?,?,?,?,?,?) ON CONFLICT(machine_id) DO UPDATE SET status=excluded.status, \
             factory_sessions=excluded.factory_sessions, doc=excluded.doc, doc_hash=excluded.doc_hash, \
             received_at=excluded.received_at",
            vec![
                int(machine_id),
                opt(outside.get("status").and_then(Value::as_str)),
                outside
                    .get("factory_sessions")
                    .and_then(Value::as_i64)
                    .map_or(Param::Null, int),
                text(&doc),
                text(&doc_hash(&doc)),
                text(now),
            ],
        ),
    ];
    let num = |v: &Value| crate::util::number(Some(v));
    for (month, agents) in outside
        .get("months")
        .and_then(Value::as_object)
        .into_iter()
        .flatten()
    {
        for (agent, usd) in agents.as_object().into_iter().flatten() {
            out.push((
                "INSERT INTO outside_months (machine_id, month, agent, cost_usd) VALUES (?,?,?,?)",
                vec![int(machine_id), text(month), text(agent), real(num(usd))],
            ));
        }
    }
    for (month, models) in outside
        .get("unpriced")
        .and_then(Value::as_object)
        .into_iter()
        .flatten()
    {
        for (model, tokens) in models.as_object().into_iter().flatten() {
            out.push((
                "INSERT INTO outside_unpriced (machine_id, month, model, tokens) VALUES (?,?,?,?)",
                vec![
                    int(machine_id),
                    text(month),
                    text(model),
                    int(num(tokens) as i64),
                ],
            ));
        }
    }
    for (n, c) in outside
        .get("by_cwd")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .enumerate()
    {
        let get = |k: &str| c.get(k).map_or(0.0, num);
        out.push((
            "INSERT INTO outside_cwds (machine_id, seq, cwd, sessions, claude_usd, codex_usd) \
             VALUES (?,?,?,?,?,?)",
            vec![
                int(machine_id),
                int(n as i64),
                opt(c.get("cwd").and_then(Value::as_str)),
                int(get("sessions") as i64),
                real(get("claude")),
                real(get("codex")),
            ],
        ));
    }
    out
}

impl Hub {
    /// Apply one ingest payload.
    pub async fn ingest(&self, p: &Value) -> Result<Outcome, IngestError> {
        let Some(p) = p.as_object() else {
            return bad("body must be an object");
        };
        let machine = match p.get("machine").and_then(Value::as_str) {
            Some(m) if !m.is_empty() && !m.contains('/') => m,
            _ => return bad("machine missing"),
        };
        let repos = match p.get("repos") {
            None => &[][..],
            Some(Value::Array(a)) => a,
            Some(_) => return bad("repos must be a list"),
        };
        let full = p.get("full").is_some_and(truthy);
        let now = now_iso();

        let _one_at_a_time = self.ingest_lock.lock().await;
        let mut ids = Ids::default();
        let known = id_of(
            &self.store,
            "SELECT id FROM machines WHERE name=?",
            vec![text(machine)],
        )
        .await?;
        let mut need_full = !full && known.is_none();
        let machine_id = match known {
            Some(id) => id,
            None => ids.next(&self.store, "machines").await?,
        };
        let mut stmts: Vec<Statement> = vec![(
            "INSERT INTO machines (id, name, first_seen, last_seen) VALUES (?, ?, ?, ?) \
             ON CONFLICT(id) DO UPDATE SET last_seen=excluded.last_seen",
            vec![int(machine_id), text(machine), text(&now), text(&now)],
        )];
        if let Some(subs) = p.get("subscriptions") {
            stmts.extend(subscription_statements(machine_id, subs));
        }
        if let Some(outside) = p.get("outside") {
            stmts.extend(outside_statements(machine_id, outside, &now));
        }

        let mut events = Vec::new();
        let mut changed = 0;
        let mut names = Vec::new();
        let mut listed = HashSet::new();
        for r in repos {
            let repo = match r.get("repo").and_then(Value::as_str) {
                Some(name) if r.is_object() && valid_repo(name) => name,
                _ => return bad("bad repo name"),
            };
            if !listed.insert(repo.to_owned()) {
                continue; // the same repo twice: the first one counts
            }
            names.push(repo.to_owned());
            let ctx = RepoCtx {
                machine,
                machine_id,
                repo,
                full,
                now: &now,
            };
            need_full |= self
                .ingest_repo(&ctx, r, &mut ids, &mut stmts, &mut events)
                .await?;
            changed += match r.get("jobs") {
                Some(Value::Array(a)) => a.len(),
                Some(Value::Object(o)) => o.len(),
                _ => 0,
            };
        }
        if full {
            let held = self
                .store
                .query(
                    "SELECT c.id AS id, r.slug AS slug FROM checkouts c JOIN repos r ON r.id=c.repo_id \
                     WHERE c.machine_id=? AND c.removed_at IS NULL",
                    vec![int(machine_id)],
                )
                .await?;
            for row in held {
                if !listed.contains(get_or_empty(&row, "slug")) {
                    stmts.push((
                        "UPDATE checkouts SET removed_at=? WHERE id=?",
                        vec![text(&now), int(get_int(&row, "id").unwrap_or(0))],
                    ));
                }
            }
        }
        self.store.batch(stmts).await?;

        for e in &events {
            self.broker.publish("job", &e.to_json());
        }
        self.broker
            .publish("seen", &json!({"machine": machine, "at": now}));
        Ok(Outcome {
            machine: machine.to_owned(),
            need_full,
            changed,
            repos: names,
        })
    }

    /// Append the statements for one repo of an ingest; true when it needs a full push.
    #[allow(clippy::too_many_lines)]
    async fn ingest_repo(
        &self,
        ctx: &RepoCtx<'_>,
        r: &Value,
        ids: &mut Ids,
        stmts: &mut Vec<Statement>,
        events: &mut Vec<Event>,
    ) -> Result<bool, IngestError> {
        let RepoCtx {
            machine,
            machine_id,
            repo,
            full,
            now,
        } = *ctx;
        let mut need_full = false;
        let string_or_null = |name: &str| match r.get(name) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(s)) => Ok(Some(s.as_str())),
            Some(_) => bad(&format!("bad {name}")),
        };
        let url = string_or_null("url")?;
        let path = string_or_null("path")?;

        let repo_id = match id_of(
            &self.store,
            "SELECT id FROM repos WHERE slug=?",
            vec![text(repo)],
        )
        .await?
        {
            Some(id) => id,
            None => ids.next(&self.store, "repos").await?,
        };
        stmts.push((
            "INSERT INTO repos (id, slug, url, first_seen) VALUES (?, ?, ?, ?) \
             ON CONFLICT(id) DO UPDATE SET url=COALESCE(excluded.url, repos.url)",
            vec![int(repo_id), text(repo), opt(url), text(now)],
        ));
        let held_checkout = id_of(
            &self.store,
            "SELECT id FROM checkouts WHERE machine_id=? AND repo_id=?",
            vec![int(machine_id), int(repo_id)],
        )
        .await?;
        if held_checkout.is_none() {
            need_full = !full;
        }
        let checkout_id = match held_checkout {
            Some(id) => id,
            None => ids.next(&self.store, "checkouts").await?,
        };
        stmts.push((
            "INSERT INTO checkouts (id, machine_id, repo_id, path, first_seen, last_seen) \
             VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET path=excluded.path, \
             last_seen=excluded.last_seen, removed_at=NULL",
            vec![
                int(checkout_id),
                int(machine_id),
                int(repo_id),
                opt(path),
                text(now),
                text(now),
            ],
        ));
        if let Some(config) = r.get("config") {
            let doc = config.to_string();
            stmts.push((
                "UPDATE checkouts SET config_doc=?, config_hash=? WHERE id=?",
                vec![text(&doc), text(&doc_hash(&doc)), int(checkout_id)],
            ));
        }

        let mut held: HashMap<String, Held> = self
            .store
            .query(
                "SELECT id, job_key, doc_hash, stage, first_seen, removed_at FROM jobs WHERE checkout_id=?",
                vec![int(checkout_id)],
            )
            .await?
            .iter()
            .map(|row| {
                (
                    get_or_empty(row, "job_key").to_owned(),
                    Held {
                        id: get_int(row, "id").unwrap_or(0),
                        hash: get_or_empty(row, "doc_hash").to_owned(),
                        stage: store::get(row, "stage").map(str::to_owned),
                        first_seen: get_or_empty(row, "first_seen").to_owned(),
                        removed: row.get("removed_at").is_some_and(|v| !v.is_null()),
                    },
                )
            })
            .collect();

        let mut sent = HashSet::new();
        for j in list_of(r.get("jobs"), "bad job id")? {
            let key = match j.get("id").and_then(Value::as_str) {
                Some(id) if j.is_object() && safe_path(id) && !id.contains('/') => id,
                _ => return bad("bad job id"),
            };
            if !sent.insert(key.to_owned()) {
                continue;
            }
            let doc = match j.get("job") {
                Some(job) => {
                    expect(job.is_object(), "job must be an object")?;
                    Some(job)
                }
                None => None,
            };
            let files = map_of(j.get("files"), "files must be an object")?;
            let removed = list_of(j.get("files_removed"), "bad files_removed")?;
            for (path, content) in files.into_iter().flatten() {
                expect(content.is_string() && safe_path(path), "bad file")?;
            }
            let before = held.get(key);
            if before.is_none() && doc.is_none() {
                need_full = true; // files for a job we never saw the job.json of
                continue;
            }
            let job_id = match before {
                Some(h) => h.id,
                None => ids.next(&self.store, "jobs").await?,
            };

            // the job's files after this push: first lines for the projection
            let mut lines: HashMap<String, String> = if before.is_some() {
                self.store
                    .query(
                        "SELECT path, first_line FROM job_files WHERE job_id=?",
                        vec![int(job_id)],
                    )
                    .await?
                    .iter()
                    .map(|row| {
                        (
                            get_or_empty(row, "path").to_owned(),
                            get_or_empty(row, "first_line").to_owned(),
                        )
                    })
                    .collect()
            } else {
                HashMap::new()
            };
            let mut files_changed = false;
            let mut file_stmts: Vec<Statement> = Vec::new();
            if full {
                let gone: Vec<String> = lines
                    .keys()
                    .filter(|p| !files.is_some_and(|f| f.contains_key(*p)))
                    .cloned()
                    .collect();
                for path in gone {
                    lines.remove(&path);
                    files_changed = true;
                    file_stmts.push((
                        "DELETE FROM job_files WHERE job_id=? AND path=?",
                        vec![int(job_id), text(&path)],
                    ));
                }
            }
            for (path, content) in files.into_iter().flatten() {
                let content = content.as_str().unwrap_or("");
                let line = first_line(content);
                lines.insert(path.clone(), line.to_owned());
                files_changed = true;
                file_stmts.push((
                    "INSERT INTO job_files (job_id, path, content, first_line, updated) VALUES (?,?,?,?,?) \
                     ON CONFLICT(job_id, path) DO UPDATE SET content=excluded.content, \
                     first_line=excluded.first_line, updated=excluded.updated",
                    vec![int(job_id), text(path), text(content), text(line), text(now)],
                ));
            }
            for path in removed {
                if let Some(path) = path.as_str() {
                    files_changed |= lines.remove(path).is_some();
                    file_stmts.push((
                        "DELETE FROM job_files WHERE job_id=? AND path=?",
                        vec![int(job_id), text(path)],
                    ));
                }
            }

            let doc_text = doc.map(Value::to_string);
            let hash = doc_text.as_deref().map(doc_hash);
            let doc_changed = match (&hash, before) {
                (Some(h), Some(b)) => *h != b.hash,
                (Some(_), None) => true,
                (None, _) => false,
            };
            if doc_changed || files_changed {
                // the document to project: the one sent, else the stored one
                let (doc_text, hash) = match (doc_text, hash) {
                    (Some(d), Some(h)) => (d, h),
                    _ => {
                        let rows = self
                            .store
                            .query(
                                "SELECT doc, doc_hash FROM jobs WHERE id=?",
                                vec![int(job_id)],
                            )
                            .await?;
                        let row = rows.first();
                        (
                            row.map(|r| get_or_empty(r, "doc").to_owned())
                                .unwrap_or_default(),
                            row.map(|r| get_or_empty(r, "doc_hash").to_owned())
                                .unwrap_or_default(),
                        )
                    }
                };
                let parsed: Value = serde_json::from_str(&doc_text).unwrap_or(Value::Null);
                let first_seen = before.map_or(now, |b| b.first_seen.as_str());
                let projection = project(
                    &parsed,
                    &lines,
                    &Seen {
                        first_seen,
                        last_seen: now,
                        removed_at: None,
                    },
                );
                if before.is_none() || before.and_then(|b| b.stage.clone()) != projection.stage {
                    events.push(Event {
                        at: now.to_owned(),
                        machine: machine.to_owned(),
                        repo: repo.to_owned(),
                        job: key.to_owned(),
                        title: projection.title.clone(),
                        from: before.and_then(|b| b.stage.clone()),
                        to: projection.stage.clone(),
                    });
                }
                stmts.push(upsert_job(
                    job_id,
                    checkout_id,
                    key,
                    &doc_text,
                    &hash,
                    &projection,
                ));
                stmts.extend(file_stmts);
                stmts.extend(projection.child_statements(job_id));
                held.insert(
                    key.to_owned(),
                    Held {
                        id: job_id,
                        hash,
                        stage: projection.stage,
                        first_seen: first_seen.to_owned(),
                        removed: false,
                    },
                );
            } else {
                stmts.push((
                    "UPDATE jobs SET last_seen=?, removed_at=NULL WHERE id=?",
                    vec![text(now), int(job_id)],
                ));
            }
        }

        match r.get("job_ids") {
            None | Some(Value::Null) => {}
            Some(Value::Array(list)) => {
                expect(list.iter().all(Value::is_string), "bad job_ids")?;
                let keep: HashSet<&str> = list.iter().filter_map(Value::as_str).collect();
                for (key, h) in &held {
                    if !keep.contains(key.as_str()) && !h.removed {
                        stmts.push((
                            "UPDATE jobs SET removed_at=? WHERE id=?",
                            vec![text(now), int(h.id)],
                        ));
                    } else if keep.contains(key.as_str()) && h.removed && !sent.contains(key) {
                        stmts.push((
                            "UPDATE jobs SET removed_at=NULL WHERE id=?",
                            vec![int(h.id)],
                        ));
                    }
                }
                need_full |= keep
                    .iter()
                    .any(|id| !held.contains_key(*id) && !sent.contains(*id));
            }
            Some(_) => return bad("bad job_ids"),
        }

        let tickets = map_of(r.get("tickets"), "tickets must be an object")?;
        for (path, content) in tickets.into_iter().flatten() {
            expect(content.is_string() && safe_path(path), "bad ticket")?;
        }
        if full {
            let sent_tickets: HashSet<&str> = tickets
                .into_iter()
                .flatten()
                .map(|(p, _)| p.as_str())
                .collect();
            let rows = self
                .store
                .query(
                    "SELECT path FROM tickets WHERE checkout_id=?",
                    vec![int(checkout_id)],
                )
                .await?;
            for row in &rows {
                let path = get_or_empty(row, "path");
                if !sent_tickets.contains(path) {
                    stmts.push((
                        "DELETE FROM tickets WHERE checkout_id=? AND path=?",
                        vec![int(checkout_id), text(path)],
                    ));
                }
            }
        }
        for (path, content) in tickets.into_iter().flatten() {
            stmts.push((
                "INSERT INTO tickets (checkout_id, path, content, updated) VALUES (?,?,?,?) \
                 ON CONFLICT(checkout_id, path) DO UPDATE SET content=excluded.content, \
                 updated=excluded.updated",
                vec![
                    int(checkout_id),
                    text(path),
                    text(content.as_str().unwrap_or("")),
                    text(now),
                ],
            ));
        }
        Ok(need_full)
    }

    /// Re-derive every job projected by an older PROJECTION_VERSION from its stored
    /// document and files. Runs at startup, before the hub takes requests.
    pub async fn reproject(&self) -> Result<usize, store::Error> {
        let stale = self
            .store
            .query(
                "SELECT id, checkout_id, job_key, doc, doc_hash, first_seen, last_seen, removed_at \
                 FROM jobs WHERE projection_version < ?",
                vec![int(crate::project::PROJECTION_VERSION)],
            )
            .await?;
        for row in &stale {
            let id = get_int(row, "id").unwrap_or(0);
            let lines: HashMap<String, String> = self
                .store
                .query(
                    "SELECT path, first_line FROM job_files WHERE job_id=?",
                    vec![int(id)],
                )
                .await?
                .iter()
                .map(|r| {
                    (
                        get_or_empty(r, "path").to_owned(),
                        get_or_empty(r, "first_line").to_owned(),
                    )
                })
                .collect();
            let doc = get_or_empty(row, "doc");
            let parsed: Value = serde_json::from_str(doc).unwrap_or(Value::Null);
            let p = project(
                &parsed,
                &lines,
                &Seen {
                    first_seen: get_or_empty(row, "first_seen"),
                    last_seen: get_or_empty(row, "last_seen"),
                    removed_at: store::get(row, "removed_at"),
                },
            );
            let mut stmts = vec![upsert_job(
                id,
                get_int(row, "checkout_id").unwrap_or(0),
                get_or_empty(row, "job_key"),
                doc,
                get_or_empty(row, "doc_hash"),
                &p,
            )];
            stmts.extend(p.child_statements(id));
            self.store.batch(stmts).await?;
        }
        Ok(stale.len())
    }
}

/// What every statement of one repo of an ingest shares.
#[derive(Clone, Copy)]
struct RepoCtx<'a> {
    machine: &'a str,
    machine_id: i64,
    repo: &'a str,
    full: bool,
    now: &'a str,
}
