//! Small helpers shared by the modules: time, URL quoting, numbers, paths.

use serde_json::{Number, Value};
use std::time::{SystemTime, UNIX_EPOCH};

pub const SECONDS_PER_DAY: i64 = 86_400;

pub fn now_epoch() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

/// Days since 1970-01-01 for a civil date (proleptic Gregorian).
pub fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// The civil date (year, month, day) of a day count since 1970-01-01.
pub fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    (y, m, d)
}

/// `2026-11-17T20:00:00Z` for an epoch second.
pub fn iso_from_epoch(secs: i64) -> String {
    let (y, m, d) = civil_from_days(secs.div_euclid(SECONDS_PER_DAY));
    let t = secs.rem_euclid(SECONDS_PER_DAY);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        t / 3600,
        t % 3600 / 60,
        t % 60
    )
}

/// `2026-11-17` for a day count since 1970-01-01.
pub fn date_from_days(days: i64) -> String {
    let (y, m, d) = civil_from_days(days);
    format!("{y:04}-{m:02}-{d:02}")
}

pub fn now_iso() -> String {
    iso_from_epoch(now_epoch())
}

/// Epoch seconds of `YYYY-MM-DD[T ]HH:MM:SS[.frac][Z|+HH:MM]` (no zone = UTC).
pub fn parse_iso(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    let num = |from: usize, len: usize| -> Option<i64> {
        let digits = b.get(from..from + len)?;
        digits
            .iter()
            .all(u8::is_ascii_digit)
            .then(|| digits.iter().fold(0, |n, c| n * 10 + i64::from(c - b'0')))
    };
    if b.get(4) != Some(&b'-') || b.get(7) != Some(&b'-') {
        return None;
    }
    let (year, month, day) = (num(0, 4)?, num(5, 2)?, num(8, 2)?);
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    let mut secs = days_from_civil(year, month, day) * SECONDS_PER_DAY;
    let mut i = 10;
    if matches!(b.get(i), Some(b'T' | b't' | b' ')) {
        let (h, mi) = (num(11, 2)?, num(14, 2)?);
        let sec = if b.get(16) == Some(&b':') {
            i = 19;
            num(17, 2)?
        } else {
            i = 16;
            0
        };
        secs += h * 3600 + mi * 60 + sec;
        if b.get(i) == Some(&b'.') {
            i += 1;
            while b.get(i).is_some_and(u8::is_ascii_digit) {
                i += 1;
            }
        }
        match b.get(i) {
            None => {}
            Some(b'Z' | b'z') if i + 1 == b.len() => {}
            Some(&sign @ (b'+' | b'-')) => {
                let (oh, om) = (num(i + 1, 2)?, num(i + 4, 2).or_else(|| num(i + 3, 2))?);
                let offset = oh * 3600 + om * 60;
                secs -= if sign == b'+' { offset } else { -offset };
            }
            Some(_) => return None,
        }
    } else if i != b.len() {
        return None;
    }
    Some(secs)
}

fn unreserved(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-' | b'~')
}

/// Python's `urllib.parse.quote`: everything but `A-Za-z0-9_.-~` and `/` is %XX.
pub fn quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for &b in s.as_bytes() {
        if unreserved(b) || b == b'/' {
            out.push(char::from(b));
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// Python's `urllib.parse.unquote`: %XX decoded as UTF-8, bad bytes replaced.
pub fn unquote(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        let hex = |c: u8| char::from(c).to_digit(16);
        if b[i] == b'%' && i + 2 < b.len() {
            if let (Some(h), Some(l)) = (hex(b[i + 1]), hex(b[i + 2])) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub fn html_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#x27;"),
            c => out.push(c),
        }
    }
    out
}

/// A relative, `..`-free path with no empty segments.
pub fn safe_path(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && !path.contains(['\\', '\0'])
        && path.split('/').all(|p| !matches!(p, "" | "." | ".."))
}

/// `owner/name`: exactly one slash, both sides safe.
pub fn valid_repo(repo: &str) -> bool {
    repo.matches('/').count() == 1 && safe_path(repo)
}

/// Python truthiness of a JSON value.
pub fn truthy(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().is_some_and(|f| f != 0.0),
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
    }
}

/// A JSON number that stays an integer until a float is added (like Python's int/float).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Num {
    Int(i64),
    Float(f64),
}

impl Num {
    pub fn of(v: Option<&Value>) -> Num {
        match v {
            Some(Value::Number(n)) => n
                .as_i64()
                .map_or_else(|| Num::Float(n.as_f64().unwrap_or(0.0)), Num::Int),
            _ => Num::Int(0),
        }
    }

    pub fn as_f64(self) -> f64 {
        match self {
            Num::Int(i) => i as f64,
            Num::Float(f) => f,
        }
    }

    pub fn add(self, other: Num) -> Num {
        match (self, other) {
            (Num::Int(a), Num::Int(b)) => a
                .checked_add(b)
                .map_or_else(|| Num::Float(a as f64 + b as f64), Num::Int),
            (a, b) => Num::Float(a.as_f64() + b.as_f64()),
        }
    }

    pub fn to_value(self) -> Value {
        match self {
            Num::Int(i) => Value::from(i),
            Num::Float(f) => Number::from_f64(f).map_or(Value::Null, Value::Number),
        }
    }
}

/// A JSON number as f64, anything else 0.
pub fn number(v: Option<&Value>) -> f64 {
    match v {
        Some(Value::Number(n)) => n.as_f64().unwrap_or(0.0),
        _ => 0.0,
    }
}

/// Python's `round(x, 4)` (exact decimal rounding, half to even).
pub fn round4(x: f64) -> f64 {
    format!("{x:.4}").parse().unwrap_or(x)
}

pub fn float(x: f64) -> Value {
    Number::from_f64(x).map_or(Value::Null, Value::Number)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso_roundtrip() {
        assert_eq!(iso_from_epoch(0), "1970-01-01T00:00:00Z");
        let t = parse_iso("2026-11-17T20:00:00Z").unwrap();
        assert_eq!(iso_from_epoch(t), "2026-11-17T20:00:00Z");
        assert_eq!(parse_iso("2026-11-17T22:00:00+02:00"), Some(t));
        assert_eq!(parse_iso("2026-11-17T20:00:00.123Z"), Some(t));
        assert_eq!(parse_iso("nope"), None);
    }

    #[test]
    fn quoting() {
        assert_eq!(quote("a b/ü"), "a%20b/%C3%BC");
        assert_eq!(unquote("a%20b/%C3%BC%zz%2"), "a b/ü%zz%2");
    }

    #[test]
    fn paths() {
        assert!(valid_repo("o/r"));
        assert!(!valid_repo("o/r/x"));
        assert!(!valid_repo("../r"));
        assert!(!safe_path("a//b"));
    }
}
