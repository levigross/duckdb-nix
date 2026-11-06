use std::fmt::Write;

/// The value of a `$parameter` of a query.
#[derive(Debug, Clone, PartialEq)]
pub enum Param {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(String),
    List(Vec<Param>),
}

impl From<bool> for Param {
    fn from(v: bool) -> Self {
        Param::Bool(v)
    }
}
impl From<i32> for Param {
    fn from(v: i32) -> Self {
        Param::Int(v.into())
    }
}
impl From<i64> for Param {
    fn from(v: i64) -> Self {
        Param::Int(v)
    }
}
impl From<f64> for Param {
    fn from(v: f64) -> Self {
        Param::Float(v)
    }
}
impl From<&str> for Param {
    fn from(v: &str) -> Self {
        Param::Str(v.to_owned())
    }
}
impl From<String> for Param {
    fn from(v: String) -> Self {
        Param::Str(v)
    }
}
impl<T: Into<Param>> From<Vec<T>> for Param {
    fn from(v: Vec<T>) -> Self {
        Param::List(v.into_iter().map(Into::into).collect())
    }
}
impl<T: Into<Param>> From<Option<T>> for Param {
    fn from(v: Option<T>) -> Self {
        v.map_or(Param::Null, Into::into)
    }
}

/// The parameters of a query, by name. The engine does not check that the type of a value fits
/// where the query uses it.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Params(Vec<(String, Param)>);

impl Params {
    pub fn new() -> Self {
        Params::default()
    }

    pub fn with(mut self, name: &str, value: impl Into<Param>) -> Self {
        self.0.push((name.to_owned(), value.into()));
        self
    }

    pub(crate) fn to_json(&self) -> String {
        let mut out = String::from("{");
        for (i, (name, value)) in self.0.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            write_string(&mut out, name);
            out.push(':');
            write_value(&mut out, value);
        }
        out.push('}');
        out
    }
}

fn write_string(out: &mut String, text: &str) {
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

fn write_value(out: &mut String, value: &Param) {
    match value {
        Param::Null => out.push_str("null"),
        Param::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Param::Int(i) => {
            let _ = write!(out, "{i}");
        }
        // JSON has no NaN or infinity
        Param::Float(f) if f.is_finite() => {
            let _ = write!(out, "{f:?}");
        }
        Param::Float(_) => out.push_str("null"),
        Param::Str(s) => write_string(out, s),
        Param::List(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_value(out, item);
            }
            out.push(']');
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_of_parameters() {
        let p = Params::new()
            .with("id", 2)
            .with("name", "Bo\"b\n")
            .with("score", 1.5)
            .with("tags", vec!["a", "b"])
            .with("none", None::<i64>);
        assert_eq!(
            p.to_json(),
            r#"{"id":2,"name":"Bo\"b\n","score":1.5,"tags":["a","b"],"none":null}"#
        );
    }
}
