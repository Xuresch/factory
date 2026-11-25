//! The embedded Turso database: versioned migrations, one connection, batches
//! that run as one transaction.
//!
//! The schema lives in hub/migrations/NNNN_*.sql. At open the hub applies every
//! migration newer than the newest row in `schema_migrations`, each in its own
//! transaction, after copying the database file to `<db>.bak-<version>` so a bad
//! migration can be rolled back by putting the copy back. A released migration
//! is never edited; a change is a new file appended to MIGRATIONS.

use std::path::Path;

use serde_json::{Map, Value};
use tokio::sync::Mutex;
use turso::{transaction::TransactionBehavior, BatchStatement, Builder, Connection};

pub use turso::Error;

pub type Row = Map<String, Value>;
pub type Param = turso::Value;

/// `(version, sql)`, in order.
const MIGRATIONS: [(i64, &str); 4] = [
    (1, include_str!("../migrations/0001_schema.sql")),
    (2, include_str!("../migrations/0002_cost_split.sql")),
    (3, include_str!("../migrations/0003_subscription_since.sql")),
    (4, include_str!("../migrations/0004_template_version.sql")),
];

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

pub fn real(n: f64) -> Param {
    Param::Real(n)
}

pub struct Store {
    conn: Mutex<Connection>,
}

async fn connect(path: &str) -> Result<Connection, Error> {
    let db = Builder::new_local(path).build().await?;
    let conn = db.connect()?;
    conn.execute("PRAGMA foreign_keys=ON", ()).await?;
    Ok(conn)
}

async fn applied_version(conn: &Connection) -> Result<i64, Error> {
    conn.execute(
        "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)",
        (),
    )
    .await?;
    let mut rows = conn
        .query(
            "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
            (),
        )
        .await?;
    Ok(match rows.next().await? {
        Some(row) => match row.get_value(0)? {
            Param::Integer(v) => v,
            _ => 0,
        },
        None => 0,
    })
}

/// Copy the database (and its WAL) before migrating it.
fn backup(path: &str, version: i64) -> Result<Option<String>, String> {
    let source = Path::new(path);
    match std::fs::metadata(source) {
        Ok(m) if m.len() > 0 => {}
        _ => return Ok(None),
    }
    let target = format!("{path}.bak-{version}");
    std::fs::copy(source, &target).map_err(|e| format!("cannot back up {path}: {e}"))?;
    let wal = format!("{path}-wal");
    if Path::new(&wal).exists() {
        std::fs::copy(&wal, format!("{target}-wal"))
            .map_err(|e| format!("cannot back up {wal}: {e}"))?;
    }
    Ok(Some(target))
}

impl Store {
    pub async fn open(path: &str) -> Result<Store, String> {
        let db_error = |e: Error| e.to_string();
        let existed = Path::new(path).exists();
        let conn = connect(path).await.map_err(db_error)?;
        let current = applied_version(&conn).await.map_err(db_error)?;
        let pending: Vec<_> = MIGRATIONS.iter().filter(|(v, _)| *v > current).collect();
        let conn = if pending.is_empty() || path == ":memory:" {
            conn
        } else {
            drop(conn); // let go of the file while it is copied
            if let Some(copy) = backup(path, current)?.filter(|_| existed) {
                eprintln!("hub: database backed up to {copy}");
            }
            connect(path).await.map_err(db_error)?
        };
        for (version, sql) in pending {
            let script = format!(
                "BEGIN IMMEDIATE;\n{sql}\nINSERT INTO schema_migrations (version, applied_at) \
                 VALUES ({version}, '{}');\nCOMMIT;",
                crate::util::now_iso()
            );
            if let Err(e) = conn.execute_batch(&script).await {
                let _ = conn.execute("ROLLBACK", ()).await;
                return Err(format!("migration {version} failed: {e}"));
            }
            eprintln!("hub: applied migration {version}");
        }
        Ok(Store {
            conn: Mutex::new(conn),
        })
    }

    pub async fn query(&self, sql: &str, params: Vec<Param>) -> Result<Vec<Row>, Error> {
        let conn = self.conn.lock().await;
        let mut rows = conn.query(sql, params).await.inspect_err(|e| {
            eprintln!("hub: query failed: {e}: {sql}");
        })?;
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
        if statements.is_empty() {
            return Ok(());
        }
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

/// An integer column of a row.
pub fn get_int(row: &Row, column: &str) -> Option<i64> {
    row.get(column).and_then(Value::as_i64)
}

/// A number column of a row, 0 when NULL.
pub fn get_f64(row: &Row, column: &str) -> f64 {
    row.get(column).and_then(Value::as_f64).unwrap_or(0.0)
}
