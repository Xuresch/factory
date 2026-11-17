//! All database access: plain SQL with `?` parameters, rows as JSON maps.
//!
//! The embedded Turso database is the only backend. Nothing outside this file
//! touches a driver, a cursor or a PRAGMA.

use serde_json::{Map, Value};
use tokio::sync::Mutex;
use turso::transaction::TransactionBehavior;
use turso::{BatchStatement, Builder, Connection};

pub use turso::Error;

pub type Row = Map<String, Value>;
pub type Param = turso::Value;

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS machines (
    machine TEXT PRIMARY KEY, last_seen TEXT NOT NULL,
    subscriptions TEXT, outside TEXT);
CREATE TABLE IF NOT EXISTS repos (
    machine TEXT NOT NULL, repo TEXT NOT NULL, url TEXT, path TEXT,
    config TEXT, last_seen TEXT NOT NULL, PRIMARY KEY (machine, repo));
CREATE TABLE IF NOT EXISTS jobs (
    machine TEXT NOT NULL, repo TEXT NOT NULL, id TEXT NOT NULL,
    job TEXT NOT NULL, PRIMARY KEY (machine, repo, id));
CREATE TABLE IF NOT EXISTS files (
    machine TEXT NOT NULL, repo TEXT NOT NULL, job_id TEXT NOT NULL,
    path TEXT NOT NULL, content TEXT NOT NULL,
    PRIMARY KEY (machine, repo, job_id, path));
CREATE TABLE IF NOT EXISTS tickets (
    machine TEXT NOT NULL, repo TEXT NOT NULL, path TEXT NOT NULL,
    content TEXT NOT NULL, updated TEXT NOT NULL,
    PRIMARY KEY (machine, repo, path));
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, machine TEXT NOT NULL,
    repo TEXT NOT NULL, job TEXT NOT NULL, title TEXT, from_stage TEXT, to_stage TEXT);
";

/// `(sql, params)`: one statement of a batch.
pub type Statement = (&'static str, Vec<Param>);

pub fn text(s: &str) -> Param {
    Param::Text(s.to_owned())
}

pub fn opt(s: Option<&str>) -> Param {
    s.map_or(Param::Null, text)
}

pub fn int(n: i64) -> Param {
    Param::Integer(n)
}

pub struct Store {
    conn: Mutex<Connection>,
}

impl Store {
    pub async fn open(path: &str) -> Result<Store, Error> {
        let db = Builder::new_local(path).build().await?;
        let conn = db.connect()?;
        conn.execute_batch(SCHEMA).await?;
        Ok(Store {
            conn: Mutex::new(conn),
        })
    }

    pub async fn query(&self, sql: &str, params: Vec<Param>) -> Result<Vec<Row>, Error> {
        let conn = self.conn.lock().await;
        let mut rows = conn.query(sql, params).await?;
        let names = rows.column_names();
        let mut out = Vec::new();
        while let Some(row) = rows.next().await? {
            let mut map = Row::new();
            for (i, name) in names.iter().enumerate() {
                map.insert(name.clone(), json(row.get_value(i)?));
            }
            out.push(map);
        }
        Ok(out)
    }

    pub async fn execute(&self, sql: &'static str, params: Vec<Param>) -> Result<(), Error> {
        self.batch(vec![(sql, params)]).await
    }

    /// Run the statements as one transaction: all or nothing.
    pub async fn batch(&self, statements: Vec<Statement>) -> Result<(), Error> {
        let statements = statements
            .into_iter()
            .map(|(sql, params)| BatchStatement::new(sql, params))
            .collect::<Result<Vec<_>, _>>()?;
        let conn = self.conn.lock().await;
        conn.transactional_batch(statements, TransactionBehavior::Immediate)
            .await?;
        Ok(())
    }
}

fn json(v: Param) -> Value {
    match v {
        Param::Null | Param::Blob(_) => Value::Null,
        Param::Integer(i) => Value::from(i),
        Param::Real(f) => serde_json::Number::from_f64(f).map_or(Value::Null, Value::Number),
        Param::Text(s) => Value::String(s),
    }
}

/// A text column of a row.
pub fn get<'a>(row: &'a Row, column: &str) -> Option<&'a str> {
    row.get(column).and_then(Value::as_str)
}

/// A text column of a row, empty when NULL.
pub fn get_or_empty<'a>(row: &'a Row, column: &str) -> &'a str {
    get(row, column).unwrap_or("")
}
