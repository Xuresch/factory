//! The factory hub: one web app every factory reports to.
//!
//! Reporters (factory/bin/report, one per machine) POST what changed in their
//! repos' factory/ folders to /api/ingest. The hub keeps it in an embedded
//! Turso database and serves
//!
//!   /                      the overview page (hub/static/index.html), live over SSE
//!   /static/<name>         any other file in hub/static/
//!   /api/overview          JSON for the overview
//!   /api/stream            text/event-stream: `job` and `seen` events
//!   /healthz               ok
//!   /r/<owner>/<name>/     a virtual factory/ tree of one repo: the same paths
//!                          factory/bin/dashboard serves, so factory/dashboard.html
//!                          runs under it unchanged
//!   /all/                  the same tree over every repo at once
//!
//! The contract (payloads, paths, stage sets) is hub/PROTOCOL.md.
//!
//! Environment:
//!   FACTORY_HUB_BIND        interface to listen on (default 127.0.0.1)
//!   FACTORY_HUB_PORT        port (default 8080)
//!   FACTORY_HUB_DB          database file (default ./hub.db)
//!   FACTORY_HUB_TOKENS      comma-separated ingest tokens; empty refuses all ingest (403)
//!   FACTORY_HUB_DASHBOARD   the dashboard.html to serve per repo
//!                           (default factory/dashboard.html next to hub/)
//!   FACTORY_HUB_STATIC      folder served at / and /static/ (default hub/static/)
//!
//! `factory-hub --healthcheck` asks a running hub on this machine for /healthz
//! and exits 0 (ok) or 1.
//!
//! Viewing has no login of its own; put the hub behind an auth proxy and leave
//! /api/ingest and /healthz outside it, since ingest is token-only.

mod api;
mod ingest;
mod overview;
mod project;
mod sse;
mod store;
#[cfg(test)]
mod subscription_tests;
mod subscriptions;
mod tree;
mod util;

use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use axum::body::{to_bytes, Body};
use axum::extract::{Request, State};
use axum::http::header::{CACHE_CONTROL, CONNECTION, CONTENT_TYPE, LOCATION};
use axum::http::{HeaderMap, HeaderName, HeaderValue, Method, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Router;
use serde_json::{json, Value};
use tokio::sync::Mutex;

use ingest::IngestError;
use store::Store;
use tree::Answer;
use util::{quote, unquote};

const MAX_BODY: usize = 64 * 1024 * 1024;
const TEXT: &str = "text/plain; charset=utf-8";
const JSON: &str = "application/json";

/// The store, the ingest rules and the read model.
pub struct Hub {
    pub store: Store,
    pub broker: sse::Broker,
    tokens: Vec<String>,
    dashboard: PathBuf,
    static_dir: PathBuf,
    /// Ingests read then write; one at a time.
    ingest_lock: Mutex<()>,
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok()
}

fn port() -> Result<u16, String> {
    let port = env("FACTORY_HUB_PORT").unwrap_or_else(|| "8080".to_owned());
    port.trim()
        .parse()
        .map_err(|_| format!("FACTORY_HUB_PORT is not a port: {port}"))
}

/// `--healthcheck`: GET /healthz on this machine, true on a 200.
fn healthcheck() -> bool {
    let Ok(port) = port() else { return false };
    let timeout = Duration::from_secs(2);
    let Some(addr) = ("127.0.0.1", port)
        .to_socket_addrs()
        .ok()
        .and_then(|mut a| a.next())
    else {
        return false;
    };
    let Ok(mut conn) = TcpStream::connect_timeout(&addr, timeout) else {
        return false;
    };
    let _ = conn.set_read_timeout(Some(timeout));
    let _ = conn.set_write_timeout(Some(timeout));
    let request = "GET /healthz HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n";
    let mut answer = [0; 12];
    conn.write_all(request.as_bytes()).is_ok()
        && conn.read_exact(&mut answer).is_ok()
        && answer.starts_with(b"HTTP/1.")
        && answer.ends_with(b" 200")
}

fn main() -> ExitCode {
    if std::env::args().nth(1).as_deref() == Some("--healthcheck") {
        return if healthcheck() {
            ExitCode::SUCCESS
        } else {
            ExitCode::FAILURE
        };
    }
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("hub: cannot start the runtime: {e}");
            return ExitCode::FAILURE;
        }
    };
    match runtime.block_on(run()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("hub: {message}");
            ExitCode::FAILURE
        }
    }
}

async fn run() -> Result<(), String> {
    let bind = env("FACTORY_HUB_BIND").unwrap_or_else(|| "127.0.0.1".to_owned());
    let port = port()?;
    let tokens: Vec<String> = env("FACTORY_HUB_TOKENS")
        .unwrap_or_default()
        .split(',')
        .map(|t| t.trim().to_owned())
        .filter(|t| !t.is_empty())
        .collect();
    let here = env!("CARGO_MANIFEST_DIR");
    let path_env = |name: &str, default: String| {
        PathBuf::from(env(name).filter(|v| !v.is_empty()).unwrap_or(default))
    };
    let db = env("FACTORY_HUB_DB").unwrap_or_else(|| "./hub.db".to_owned());
    let store = Store::open(&db)
        .await
        .map_err(|e| format!("cannot open the database {db}: {e}"))?;
    let hub = Arc::new(Hub {
        store,
        broker: sse::Broker::default(),
        dashboard: path_env(
            "FACTORY_HUB_DASHBOARD",
            format!("{here}/../factory/dashboard.html"),
        ),
        static_dir: path_env("FACTORY_HUB_STATIC", format!("{here}/static")),
        tokens,
        ingest_lock: Mutex::new(()),
    });
    let reprojected = hub
        .reproject()
        .await
        .map_err(|e| format!("cannot re-project the jobs: {e}"))?;
    if reprojected > 0 {
        println!("hub: re-projected {reprojected} jobs");
    }

    let host = if bind.is_empty() {
        "0.0.0.0"
    } else {
        bind.as_str()
    };
    let listener = tokio::net::TcpListener::bind((host, port))
        .await
        .map_err(|e| format!("cannot listen on {host}:{port}: {e}"))?;
    let actual = listener.local_addr().map_or(port, |a| a.port());
    let shown = if matches!(bind.as_str(), "0.0.0.0" | "") {
        "127.0.0.1"
    } else {
        bind.as_str()
    };
    println!(
        "hub: http://{shown}:{actual}/{}",
        if hub.tokens.is_empty() {
            " (no FACTORY_HUB_TOKENS: ingest refused)"
        } else {
            ""
        }
    );

    let app = Router::new().fallback(handle).with_state(hub.clone());
    axum::serve(listener, app)
        .with_graceful_shutdown(async move {
            shutdown_signal().await;
            hub.broker.close(); // open event streams would hold the shutdown up
        })
        .await
        .map_err(|e| format!("server error: {e}"))
}

async fn shutdown_signal() {
    use tokio::signal::unix::{signal, SignalKind};
    let term = async {
        match signal(SignalKind::terminate()) {
            Ok(mut s) => {
                s.recv().await;
            }
            Err(_) => std::future::pending().await,
        }
    };
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        () = term => {}
    }
}

// ---- HTTP ------------------------------------------------------------------

fn header(value: &str) -> HeaderValue {
    HeaderValue::from_str(value).unwrap_or_else(|_| HeaderValue::from_static(""))
}

fn reply(status: u16, ctype: &str, body: impl Into<Body>) -> Response {
    let mut res = Response::new(body.into());
    *res.status_mut() = StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    res.headers_mut().insert(CONTENT_TYPE, header(ctype));
    res.headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    res
}

fn reply_json(status: u16, data: &Value) -> Response {
    reply(status, JSON, data.to_string())
}

fn not_found() -> Response {
    reply(404, TEXT, "not found\n")
}

/// Close the connection after this reply (set on every refused POST).
fn close(mut res: Response) -> Response {
    res.headers_mut()
        .insert(CONNECTION, HeaderValue::from_static("close"));
    res
}

fn redirect(location: &str) -> Response {
    let mut res = reply(301, TEXT, "");
    res.headers_mut().insert(LOCATION, header(location));
    res
}

fn server_error(error: &store::Error) -> Response {
    eprintln!("hub: database error: {error}");
    reply_json(500, &json!({"error": "internal error"}))
}

fn answer(a: Answer) -> Response {
    reply(a.status, a.ctype, a.body)
}

async fn handle(State(hub): State<Arc<Hub>>, req: Request) -> Response {
    match *req.method() {
        Method::GET | Method::HEAD => {
            let head = req.method() == Method::HEAD;
            get(
                &hub,
                req.uri().path(),
                req.uri().query().unwrap_or(""),
                head,
            )
            .await
        }
        Method::POST => post(&hub, req).await,
        _ => close(reply(501, TEXT, "unsupported method\n")),
    }
}

// -- GET --

async fn get(hub: &Hub, raw: &str, query: &str, head: bool) -> Response {
    let path = unquote(raw);
    if path.contains('\0') || path.split('/').any(|p| p == "..") {
        return not_found();
    }
    match path.as_str() {
        "/healthz" => reply(200, TEXT, "ok\n"),
        "/api/overview" => match hub.overview().await {
            Ok(v) => reply_json(200, &v),
            Err(e) => server_error(&e),
        },
        "/api/stream" => stream(hub, head),
        "/api/costs" => api_costs(hub, query).await,
        "/" => static_file(hub, "index.html").await,
        "/all" | "/all/" => redirect("/all/dashboard.html"),
        _ => {
            if let Some(rest) = path.strip_prefix("/api/repos/") {
                api_repo(hub, rest, query).await
            } else if let Some(rest) = path.strip_prefix("/api/all/jobs") {
                api_jobs(hub, None, rest, query).await
            } else if let Some(name) = path.strip_prefix("/static/") {
                static_file(hub, name).await
            } else if let Some(rest) = path.strip_prefix("/all/") {
                tree(hub, None, rest, raw).await
            } else if let Some(rest) = path.strip_prefix("/r/") {
                repo_tree(hub, rest, raw).await
            } else {
                not_found()
            }
        }
    }
}

fn query_value(query: &str, key: &str) -> Option<String> {
    query
        .split('&')
        .filter_map(|part| part.split_once('='))
        .find(|(k, _)| *k == key)
        .map(|(_, v)| unquote(&v.replace('+', " ")))
}

async fn api_repo(hub: &Hub, path: &str, query: &str) -> Response {
    let mut parts = path.splitn(4, '/');
    let (Some(owner), Some(name), Some("jobs")) = (parts.next(), parts.next(), parts.next()) else {
        return reply_json(404, &json!({"error": "not found"}));
    };
    if owner.is_empty() || name.is_empty() {
        return reply_json(404, &json!({"error": "not found"}));
    }
    let repo = format!("{owner}/{name}");
    let rest = parts.next().map_or(String::new(), |id| format!("/{id}"));
    api_jobs(hub, Some(&repo), &rest, query).await
}

async fn api_jobs(hub: &Hub, repo: Option<&str>, rest: &str, query: &str) -> Response {
    let result = if rest.is_empty() {
        hub.api_jobs(repo, query_value(query, "removed").as_deref() == Some("1"))
            .await
    } else if let Some(id) = rest
        .strip_prefix('/')
        .filter(|id| !id.is_empty() && !id.contains('/'))
    {
        hub.api_detail(repo, id).await
    } else {
        return reply_json(404, &json!({"error": "not found"}));
    };
    match result {
        Ok(Some(v)) => reply_json(200, &v),
        Ok(None) => reply_json(404, &json!({"error": "not found"})),
        Err(e) => server_error(&e),
    }
}

async fn api_costs(hub: &Hub, query: &str) -> Response {
    let group = query_value(query, "group").unwrap_or_default();
    let repo = query_value(query, "repo");
    let since = query_value(query, "since");
    let until = query_value(query, "until");
    match hub
        .api_costs(&group, repo.as_deref(), since.as_deref(), until.as_deref())
        .await
    {
        Ok(Some(v)) => reply_json(200, &v),
        Ok(None) => reply_json(404, &json!({"error": "not found"})),
        Err(e) => server_error(&e),
    }
}

/// `/r/<owner>/<name>/<rest>`
async fn repo_tree(hub: &Hub, path: &str, raw: &str) -> Response {
    let mut parts = path.splitn(3, '/');
    let (Some(owner), Some(name)) = (parts.next(), parts.next()) else {
        return not_found();
    };
    if owner.is_empty() || name.is_empty() {
        return not_found();
    }
    let repo = format!("{owner}/{name}");
    let rest = parts.next().unwrap_or("");
    if rest.is_empty() {
        return redirect(&format!("/r/{}/dashboard.html", quote(&repo)));
    }
    match hub
        .store
        .query(
            "SELECT 1 FROM repos r JOIN checkouts c ON c.repo_id=r.id \
             WHERE r.slug=? AND c.removed_at IS NULL LIMIT 1",
            vec![store::text(&repo)],
        )
        .await
    {
        Ok(rows) if rows.is_empty() => not_found(),
        Ok(_) => tree(hub, Some(&repo), rest, raw).await,
        Err(e) => server_error(&e),
    }
}

async fn tree(hub: &Hub, repo: Option<&str>, rest: &str, raw: &str) -> Response {
    // `jobs` and `jobs/<id>` need the slash, as python -m http.server redirects them
    if rest == "jobs"
        || (rest.starts_with("jobs/") && rest.matches('/').count() == 1 && rest != "jobs/")
    {
        return redirect(&format!("{raw}/"));
    }
    match hub.tree_answer(repo, rest).await {
        Ok(a) => answer(a),
        Err(e) => server_error(&e),
    }
}

fn mime(name: &str) -> &'static str {
    let ext = name
        .rsplit_once('.')
        .map_or("", |(_, e)| e)
        .to_ascii_lowercase();
    match ext.as_str() {
        "html" | "htm" => "text/html; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "json" | "map" => "application/json",
        "txt" => TEXT,
        "md" => "text/markdown; charset=utf-8",
        "csv" => "text/csv; charset=utf-8",
        "xml" => "text/xml; charset=utf-8",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "ico" => "image/vnd.microsoft.icon",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "wasm" => "application/wasm",
        "webmanifest" => "application/manifest+json",
        _ => "application/octet-stream",
    }
}

async fn static_file(hub: &Hub, name: &str) -> Response {
    if name.is_empty() || name.contains('/') || name.starts_with('.') {
        return not_found();
    }
    let target = hub.static_dir.join(name);
    match tokio::fs::metadata(&target).await {
        Ok(m) if m.is_file() => match tokio::fs::read(&target).await {
            Ok(body) => reply(200, mime(name), body),
            Err(_) => not_found(),
        },
        _ => not_found(),
    }
}

/// Server-sent events until the client goes away; a ping keeps proxies open.
fn stream(hub: &Hub, head_only: bool) -> Response {
    let mut res = if head_only {
        Response::new(Body::empty())
    } else {
        hub.broker.stream().into_response()
    };
    let headers = res.headers_mut();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("text/event-stream"));
    headers.insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        HeaderName::from_static("x-accel-buffering"),
        HeaderValue::from_static("no"),
    );
    res
}

// -- POST --

/// Constant time in the content; compared against every token with no early exit.
fn authorized(tokens: &[String], authorization: Option<&HeaderValue>) -> bool {
    let given: &[u8] = match authorization.map(HeaderValue::as_bytes) {
        Some(h) if h.len() >= 7 && h[..7].eq_ignore_ascii_case(b"bearer ") => &h[7..],
        _ => b"",
    };
    let mut ok = false;
    for token in tokens {
        ok |= ct_eq(given, token.as_bytes());
    }
    ok
}

fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    let mut diff = a.len() ^ b.len();
    for i in 0..a.len().max(b.len()) {
        diff |= usize::from(a.get(i).copied().unwrap_or(0) ^ b.get(i).copied().unwrap_or(0));
    }
    diff == 0
}

enum BodyError {
    TooLarge,
    Bad(String),
}

/// Inflate (when gzip) and parse the ingest body.
fn decode_body(encoding: &str, body: &[u8]) -> Result<Value, BodyError> {
    let inflated;
    let mut bytes = match encoding.trim().to_ascii_lowercase().as_str() {
        "" | "identity" => body,
        "gzip" => {
            let mut out = Vec::new();
            flate2::read::GzDecoder::new(body)
                .take(MAX_BODY as u64 + 1)
                .read_to_end(&mut out)
                .map_err(|e| BodyError::Bad(e.to_string()))?;
            if out.len() > MAX_BODY {
                return Err(BodyError::TooLarge);
            }
            inflated = out;
            &inflated
        }
        other => {
            return Err(BodyError::Bad(format!(
                "unsupported Content-Encoding {other}"
            )))
        }
    };
    bytes = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(bytes);
    serde_json::from_slice(bytes).map_err(|e| BodyError::Bad(e.to_string()))
}

async fn post(hub: &Hub, req: Request) -> Response {
    let (parts, body) = req.into_parts();
    if parts.uri.path() != "/api/ingest" {
        return close(reply(404, TEXT, "not found\n"));
    }
    if hub.tokens.is_empty() {
        let message = "ingest is disabled: no FACTORY_HUB_TOKENS";
        return close(reply_json(403, &json!({"error": message})));
    }
    if !authorized(&hub.tokens, parts.headers.get("authorization")) {
        return close(reply_json(401, &json!({"error": "bad token"})));
    }
    let length = parts
        .headers
        .get("content-length")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.trim().parse::<i64>().ok());
    let Some(length) = length else {
        return close(reply_json(
            400,
            &json!({"error": "Content-Length required"}),
        ));
    };
    if length < 0 {
        return close(reply_json(400, &json!({"error": "bad Content-Length"})));
    }
    if length > MAX_BODY as i64 {
        return close(reply_json(413, &json!({"error": "body over 64 MB"})));
    }
    let Ok(raw) = to_bytes(body, MAX_BODY).await else {
        return close(reply_json(400, &json!({"error": "bad body"})));
    };
    let encoding = header_text(&parts.headers, "content-encoding");
    let decoded = tokio::task::spawn_blocking(move || decode_body(&encoding, &raw)).await;
    let payload = match decoded {
        Ok(Ok(v)) => v,
        Ok(Err(BodyError::TooLarge)) => {
            return close(reply_json(413, &json!({"error": "body over 64 MB"})));
        }
        Ok(Err(BodyError::Bad(message))) => return reply_json(400, &json!({"error": message})),
        Err(_) => return reply_json(500, &json!({"error": "internal error"})),
    };
    match hub.ingest(&payload).await {
        Ok(done) => {
            let repos = if done.repos.is_empty() {
                "-".to_owned()
            } else {
                done.repos.join(",")
            };
            eprintln!("ingest {} {} {}", done.machine, repos, done.changed);
            reply_json(200, &json!({"ok": true, "need_full": done.need_full}))
        }
        Err(IngestError::Bad(message)) => reply_json(400, &json!({"error": message})),
        Err(IngestError::Db(e)) => server_error(&e),
    }
}

fn header_text(headers: &HeaderMap, name: &str) -> String {
    headers
        .get(name)
        .map(|v| String::from_utf8_lossy(v.as_bytes()).into_owned())
        .unwrap_or_default()
}
