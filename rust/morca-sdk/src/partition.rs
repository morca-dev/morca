//! Partition keys: the text the scheduler and the binary both make and
//! parse (docs/pipeline-protocol.md, "Partition keys"). `monthly` is
//! `YYYY-MM`, `weekly` `YYYY-Www` (ISO weeks), `daily` `YYYY-MM-DD`, `hourly`
//! `YYYY-MM-DDTHH`, and `keyed` the names the keys dataset holds.
//!
//! A key is serialised as its text, so a first step's input row
//! (`orca.steps.input`) reads as the key.

use std::fmt;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// A partition key type: one of [`Month`], [`Week`], [`Day`], [`Hour`] or
/// [`Name`].
pub trait Partition:
    Clone + fmt::Display + Serialize + DeserializeOwned + Send + Sync + 'static
{
    /// describe's `partitions.kind`.
    const KIND: &'static str;
    /// Parses a key as the scheduler writes it.
    fn parse(s: &str) -> Result<Self, String>;
}

fn num(s: &str, what: &str, key: &str) -> Result<u32, String> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return Err(format!("not a {what}: '{key}'"));
    }
    s.parse().map_err(|_| format!("not a {what}: '{key}'"))
}

fn leap(y: u32) -> bool {
    (y.is_multiple_of(4) && !y.is_multiple_of(100)) || y.is_multiple_of(400)
}

/// The number of days in a month.
pub fn days_in_month(year: u32, month: u32) -> u32 {
    match month {
        2 if leap(year) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

macro_rules! text_serde {
    ($t:ty) => {
        impl Serialize for $t {
            fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
                s.serialize_str(&self.to_string())
            }
        }
        impl<'de> Deserialize<'de> for $t {
            fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
                let s = String::deserialize(d)?;
                <$t as Partition>::parse(&s).map_err(serde::de::Error::custom)
            }
        }
    };
}

/// A month, `YYYY-MM`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Month {
    pub year: u32,
    pub month: u32,
}

impl Month {
    pub fn days(&self) -> u32 {
        days_in_month(self.year, self.month)
    }
}

impl fmt::Display for Month {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:04}-{:02}", self.year, self.month)
    }
}

impl Partition for Month {
    const KIND: &'static str = "monthly";
    fn parse(s: &str) -> Result<Self, String> {
        let (y, m) = s
            .split_once('-')
            .filter(|(y, m)| y.len() == 4 && m.len() == 2)
            .ok_or_else(|| format!("not a month (YYYY-MM): '{s}'"))?;
        let (year, month) = (num(y, "year", s)?, num(m, "month", s)?);
        if !(1..=12).contains(&month) {
            return Err(format!("not a month (YYYY-MM): '{s}'"));
        }
        Ok(Month { year, month })
    }
}
text_serde!(Month);

/// A day, `YYYY-MM-DD`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Day {
    pub year: u32,
    pub month: u32,
    pub day: u32,
}

impl fmt::Display for Day {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:04}-{:02}-{:02}", self.year, self.month, self.day)
    }
}

impl Partition for Day {
    const KIND: &'static str = "daily";
    fn parse(s: &str) -> Result<Self, String> {
        let bad = || format!("not a day (YYYY-MM-DD): '{s}'");
        if s.len() != 10 || &s[4..5] != "-" || &s[7..8] != "-" {
            return Err(bad());
        }
        let m = Month::parse(&s[..7]).map_err(|_| bad())?;
        let day = num(&s[8..], "day", s)?;
        if day < 1 || day > m.days() {
            return Err(bad());
        }
        Ok(Day {
            year: m.year,
            month: m.month,
            day,
        })
    }
}
text_serde!(Day);

/// An hour, `YYYY-MM-DDTHH`, in UTC.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Hour {
    pub day: Day,
    pub hour: u32,
}

impl fmt::Display for Hour {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}T{:02}", self.day, self.hour)
    }
}

impl Partition for Hour {
    const KIND: &'static str = "hourly";
    fn parse(s: &str) -> Result<Self, String> {
        let bad = || format!("not an hour (YYYY-MM-DDTHH): '{s}'");
        let (d, h) = s.split_once('T').ok_or_else(bad)?;
        let day = Day::parse(d).map_err(|_| bad())?;
        if h.len() != 2 {
            return Err(bad());
        }
        let hour = num(h, "hour", s)?;
        if hour > 23 {
            return Err(bad());
        }
        Ok(Hour { day, hour })
    }
}
text_serde!(Hour);

/// An ISO week, `YYYY-Www`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Week {
    pub year: u32,
    pub week: u32,
}

/// Days since 1970-01-01 of a civil date.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let yy = if m <= 2 { y - 1 } else { y };
    let era = yy.div_euclid(400);
    let yoe = yy - era * 400;
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// How many ISO weeks a year has: 53 when 1 January is a Thursday, or a
/// Wednesday in a leap year.
fn iso_weeks(year: u32) -> u32 {
    // 1970-01-01 was a Thursday: weekday 0 = Monday.
    let wd = (days_from_civil(year as i64, 1, 1) + 3).rem_euclid(7);
    if wd == 3 || (wd == 2 && leap(year)) {
        53
    } else {
        52
    }
}

impl fmt::Display for Week {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:04}-W{:02}", self.year, self.week)
    }
}

impl Partition for Week {
    const KIND: &'static str = "weekly";
    fn parse(s: &str) -> Result<Self, String> {
        let bad = || format!("not a week (YYYY-Www): '{s}'");
        if s.len() != 8 || &s[4..6] != "-W" {
            return Err(bad());
        }
        let year = num(&s[..4], "year", s)?;
        let week = num(&s[6..], "week", s)?;
        if week < 1 || week > iso_weeks(year) {
            return Err(bad());
        }
        Ok(Week { year, week })
    }
}
text_serde!(Week);

/// The partition key of a keyed pipeline: 1 to 128 bytes of
/// `[A-Za-z0-9._:/-]`, no `..`, and no `/` at either end or twice in a row
/// (src/morca/name.mojo).
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Name(pub String);

impl Name {
    /// The name as one segment of a path: each `/` written `%2F`.
    pub fn path_segment(&self) -> String {
        self.0.replace('/', "%2F")
    }
}

impl fmt::Display for Name {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl Partition for Name {
    const KIND: &'static str = "keyed";
    fn parse(s: &str) -> Result<Self, String> {
        let ok = !s.is_empty()
            && s.len() <= 128
            && s.bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._:-/".contains(&b))
            && !s.contains("..")
            && !s.contains("//")
            && !s.starts_with('/')
            && !s.ends_with('/');
        if !ok {
            return Err(format!(
                "not a name (1 to 128 bytes of A-Z a-z 0-9 . _ : - /): '{s}'"
            ));
        }
        Ok(Name(s.to_string()))
    }
}
text_serde!(Name);

/// A key as one segment of an attempt's log path.
pub(crate) fn path_segment(key: &str) -> String {
    key.replace('/', "%2F")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_round_trip() {
        for s in ["2024-01", "1999-12"] {
            assert_eq!(Month::parse(s).unwrap().to_string(), s);
        }
        for s in ["2024-02-29", "2023-12-31"] {
            assert_eq!(Day::parse(s).unwrap().to_string(), s);
        }
        assert_eq!(
            Hour::parse("2024-03-01T07").unwrap().to_string(),
            "2024-03-01T07"
        );
        assert_eq!(Week::parse("2020-W53").unwrap().to_string(), "2020-W53");
        assert_eq!(Name::parse("owner/repo").unwrap().to_string(), "owner/repo");
    }

    #[test]
    fn bad_keys() {
        for s in ["2024-13", "2024-1", "24-01", "2024-00", "x"] {
            assert!(Month::parse(s).is_err(), "{s}");
        }
        assert!(Day::parse("2023-02-29").is_err());
        assert!(Hour::parse("2024-03-01T24").is_err());
        assert!(Week::parse("2021-W53").is_err());
        for s in ["", "a..b", "/a", "a/", "a//b", "a,b"] {
            assert!(Name::parse(s).is_err(), "{s}");
        }
    }

    #[test]
    fn serialised_as_text() {
        let m = Month::parse("2024-02").unwrap();
        assert_eq!(serde_json::to_string(&m).unwrap(), "\"2024-02\"");
        let back: Month = serde_json::from_str("\"2024-02\"").unwrap();
        assert_eq!(back, m);
    }
}
