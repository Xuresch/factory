//! POST /api/ingest: validate a reporter's payload and apply it in one transaction.
//!
//! Reads what the hub holds, decides, then writes everything in one batch, so a
//! bad payload leaves nothing behind.

use std::collections::{HashMap, HashSet};

use serde_json::{json, Map, Value};

use crate::store::{self, int, opt, text, Statement};
use crate::util::{now_iso, safe_path, truthy, valid_repo};
use crate::Hub;

const KEEP_EVENTS: i64 = 5000;

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

fn stage_of(job: &Value) -> Option<String> {
    job.get("stage").and_then(Value::as_str).map(str::to_owned)
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
        let mut stmts: Vec<Statement> = vec![(
            "INSERT INTO machines (machine, last_seen) VALUES (?, ?) \
             ON CONFLICT(machine) DO UPDATE SET last_seen=excluded.last_seen",
            vec![text(machine), text(&now)],
        )];
        let known = self
            .store
            .query(
                "SELECT 1 FROM machines WHERE machine=?",
                vec![text(machine)],
            )
            .await?;
        let mut need_full = !full && known.is_empty();
        for (key, sql) in [
            (
                "subscriptions",
                "UPDATE machines SET subscriptions=? WHERE machine=?",
            ),
            ("outside", "UPDATE machines SET outside=? WHERE machine=?"),
        ] {
            if let Some(v) = p.get(key) {
                stmts.push((sql, vec![text(&v.to_string()), text(machine)]));
            }
        }

        let mut events = Vec::new();
        let mut changed = 0;
        let mut inserted = HashSet::new();
        let mut names = Vec::new();
        for r in repos {
            let repo = match r.get("repo").and_then(Value::as_str) {
                Some(name) if r.is_object() && valid_repo(name) => name,
                _ => return bad("bad repo name"),
            };
            names.push(repo.to_owned());
            let ctx = RepoCtx {
                machine,
                repo,
                full,
                now: &now,
            };
            need_full |= self
                .ingest_repo(&ctx, r, &mut inserted, &mut stmts, &mut events)
                .await?;
            changed += match r.get("jobs") {
                Some(Value::Array(a)) => a.len(),
                Some(Value::Object(o)) => o.len(),
                _ => 0,
            };
        }
        if full {
            let listed: HashSet<&str> = names.iter().map(String::as_str).collect();
            let held = self
                .store
                .query(
                    "SELECT repo FROM repos WHERE machine=?",
                    vec![text(machine)],
                )
                .await?;
            for row in held {
                let repo = store::get_or_empty(&row, "repo");
                if !listed.contains(repo) {
                    for sql in [
                        "DELETE FROM repos WHERE machine=? AND repo=?",
                        "DELETE FROM jobs WHERE machine=? AND repo=?",
                        "DELETE FROM files WHERE machine=? AND repo=?",
                        "DELETE FROM tickets WHERE machine=? AND repo=?",
                    ] {
                        stmts.push((sql, vec![text(machine), text(repo)]));
                    }
                }
            }
        }
        for e in &events {
            stmts.push((
                "INSERT INTO events (at, machine, repo, job, title, from_stage, to_stage) \
                 VALUES (?,?,?,?,?,?,?)",
                vec![
                    text(&e.at),
                    text(&e.machine),
                    text(&e.repo),
                    text(&e.job),
                    text(&e.title),
                    opt(e.from.as_deref()),
                    opt(e.to.as_deref()),
                ],
            ));
        }
        if !events.is_empty() {
            stmts.push((
                "DELETE FROM events WHERE id <= (SELECT MAX(id) FROM events) - ?",
                vec![int(KEEP_EVENTS)],
            ));
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
    async fn ingest_repo(
        &self,
        ctx: &RepoCtx<'_>,
        r: &Value,
        inserted: &mut HashSet<String>,
        stmts: &mut Vec<Statement>,
        events: &mut Vec<Event>,
    ) -> Result<bool, IngestError> {
        let RepoCtx {
            machine,
            repo,
            full,
            now,
        } = *ctx;
        let key = || vec![text(machine), text(repo)];
        let mut need_full = false;
        let held = self
            .store
            .query("SELECT 1 FROM repos WHERE machine=? AND repo=?", key())
            .await?;
        if held.is_empty() && inserted.insert(repo.to_owned()) {
            need_full = !full;
            stmts.push((
                "INSERT INTO repos (machine, repo, last_seen) VALUES (?, ?, ?)",
                vec![text(machine), text(repo), text(now)],
            ));
        }
        let string_or_null = |name: &str| match r.get(name) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(s)) => Ok(Some(s.as_str())),
            Some(_) => bad(&format!("bad {name}")),
        };
        stmts.push((
            "UPDATE repos SET url=?, path=?, last_seen=? WHERE machine=? AND repo=?",
            vec![
                opt(string_or_null("url")?),
                opt(string_or_null("path")?),
                text(now),
                text(machine),
                text(repo),
            ],
        ));
        if let Some(config) = r.get("config") {
            stmts.push((
                "UPDATE repos SET config=? WHERE machine=? AND repo=?",
                vec![text(&config.to_string()), text(machine), text(repo)],
            ));
        }

        let mut stored: HashMap<String, Option<String>> = self
            .store
            .query("SELECT id, job FROM jobs WHERE machine=? AND repo=?", key())
            .await?
            .iter()
            .map(|row| {
                let stage = serde_json::from_str::<Value>(store::get_or_empty(row, "job"))
                    .ok()
                    .and_then(|j| stage_of(&j));
                (store::get_or_empty(row, "id").to_owned(), stage)
            })
            .collect();
        let mut held_files: HashMap<String, Vec<String>> = HashMap::new();
        if full {
            let rows = self
                .store
                .query(
                    "SELECT job_id, path FROM files WHERE machine=? AND repo=?",
                    key(),
                )
                .await?;
            for row in &rows {
                held_files
                    .entry(store::get_or_empty(row, "job_id").to_owned())
                    .or_default()
                    .push(store::get_or_empty(row, "path").to_owned());
            }
        }

        let mut sent = HashSet::new();
        for j in list_of(r.get("jobs"), "bad job id")? {
            let jid = match j.get("id").and_then(Value::as_str) {
                Some(id) if j.is_object() && safe_path(id) && !id.contains('/') => id,
                _ => return bad("bad job id"),
            };
            sent.insert(jid.to_owned());
            if let Some(job) = j.get("job") {
                expect(job.is_object(), "job must be an object")?;
                let before = stored.get(jid).cloned().flatten();
                let after = stage_of(job);
                stmts.push((
                    "INSERT INTO jobs (machine, repo, id, job) VALUES (?,?,?,?) \
                     ON CONFLICT(machine, repo, id) DO UPDATE SET job=excluded.job",
                    vec![text(machine), text(repo), text(jid), text(&job.to_string())],
                ));
                if !stored.contains_key(jid) || before != after {
                    events.push(Event {
                        at: now.to_owned(),
                        machine: machine.to_owned(),
                        repo: repo.to_owned(),
                        job: jid.to_owned(),
                        title: job
                            .get("title")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_owned(),
                        from: before,
                        to: after.clone(),
                    });
                }
                stored.insert(jid.to_owned(), after);
            } else if !stored.contains_key(jid) {
                need_full = true; // files for a job we never saw the job.json of
                continue;
            }
            let files = map_of(j.get("files"), "files must be an object")?;
            if full {
                for path in held_files.get(jid).into_iter().flatten() {
                    if !files.is_some_and(|f| f.contains_key(path)) {
                        stmts.push((
                            "DELETE FROM files WHERE machine=? AND repo=? AND job_id=? AND path=?",
                            vec![text(machine), text(repo), text(jid), text(path)],
                        ));
                    }
                }
            }
            for (path, content) in files.into_iter().flatten() {
                let content = match content.as_str() {
                    Some(c) if safe_path(path) => c,
                    _ => return bad("bad file"),
                };
                stmts.push((
                    "INSERT INTO files (machine, repo, job_id, path, content) VALUES (?,?,?,?,?) \
                     ON CONFLICT(machine, repo, job_id, path) DO UPDATE SET content=excluded.content",
                    vec![text(machine), text(repo), text(jid), text(path), text(content)],
                ));
            }
            for path in list_of(j.get("files_removed"), "bad files_removed")? {
                if let Some(path) = path.as_str() {
                    stmts.push((
                        "DELETE FROM files WHERE machine=? AND repo=? AND job_id=? AND path=?",
                        vec![text(machine), text(repo), text(jid), text(path)],
                    ));
                }
            }
        }

        match r.get("job_ids") {
            None | Some(Value::Null) => {}
            Some(Value::Array(ids)) => {
                expect(ids.iter().all(Value::is_string), "bad job_ids")?;
                let keep: HashSet<&str> = ids.iter().filter_map(Value::as_str).collect();
                for jid in stored.keys().filter(|id| !keep.contains(id.as_str())) {
                    for sql in [
                        "DELETE FROM jobs WHERE machine=? AND repo=? AND id=?",
                        "DELETE FROM files WHERE machine=? AND repo=? AND job_id=?",
                    ] {
                        stmts.push((sql, vec![text(machine), text(repo), text(jid)]));
                    }
                }
                need_full |= keep
                    .iter()
                    .any(|id| !stored.contains_key(*id) && !sent.contains(*id));
            }
            Some(_) => return bad("bad job_ids"),
        }

        let tickets = map_of(r.get("tickets"), "tickets must be an object")?;
        if full {
            stmts.push((
                "DELETE FROM tickets WHERE machine=? AND repo=?",
                vec![text(machine), text(repo)],
            ));
        }
        for (path, content) in tickets.into_iter().flatten() {
            let content = match content.as_str() {
                Some(c) if safe_path(path) => c,
                _ => return bad("bad ticket"),
            };
            stmts.push((
                "INSERT INTO tickets (machine, repo, path, content, updated) VALUES (?,?,?,?,?) \
                 ON CONFLICT(machine, repo, path) DO UPDATE SET content=excluded.content, \
                 updated=excluded.updated",
                vec![
                    text(machine),
                    text(repo),
                    text(path),
                    text(content),
                    text(now),
                ],
            ));
        }
        Ok(need_full)
    }
}

/// What every statement of one repo of an ingest shares.
#[derive(Clone, Copy)]
struct RepoCtx<'a> {
    machine: &'a str,
    repo: &'a str,
    full: bool,
    now: &'a str,
}
