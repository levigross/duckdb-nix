//! With `--features durable-s3`: keep a database in S3, or in a store that speaks its protocol,
//! over TLS. The crate does that with ureq and rustls, so this is where the program itself
//! needs a TLS stack, whichever one its build script used.
//!
//! `write` creates a durable object and flushes a table to the store. `read` opens the same
//! object, from nothing but what the store holds, and counts what was written.

use chdb_rust::durable::{Namespace, OpenOptions};
use chdb_rust::format::OutputFormat;

fn options() -> OpenOptions {
    OpenOptions {
        database: Some("mem".to_string()),
        ..OpenOptions::default()
    }
}

pub fn run(url: &str, action: &str) -> Result<(), String> {
    let namespace = Namespace::new(url)
        .map_err(|e| format!("the namespace {url}: {e}"))?
        .with_owner("chdb-rust-consumer");
    let (object, existed) = namespace
        .open("events", options())
        .map_err(|e| format!("opening the object: {e}"))?;

    match action {
        "write" => {
            if existed {
                return Err("the object existed before it was written".to_string());
            }
            let fail = |what: &str| {
                let what = what.to_string();
                move |e: chdb_rust::durable::Error| format!("{what}: {e}")
            };
            object
                .execute("CREATE TABLE events (id UInt64, tag String) ENGINE = MergeTree ORDER BY id")
                .map_err(fail("creating the table"))?;
            let ticket = object
                .execute("INSERT INTO events VALUES (1, 'first'), (2, 'second'), (3, 'third')")
                .map_err(fail("inserting"))?;
            // the barrier after which the write has left this machine
            object.flush_through(ticket).map_err(fail("flushing"))?;
            object.checkpoint().map_err(fail("checkpointing"))?;
            object.close().map_err(fail("closing"))?;
            println!("wrote 3 rows to {url}");
            Ok(())
        }
        "read" => {
            if !existed {
                return Err("the object is not in the store".to_string());
            }
            let rows = object
                .query("SELECT count() FROM events", OutputFormat::CSV)
                .map_err(|e| format!("counting: {e}"))?;
            let rows = String::from_utf8_lossy(&rows).trim().to_string();
            if rows != "3" {
                return Err(format!("expected 3 rows from the store, got {rows}"));
            }
            println!("read 3 rows back from {url}");
            Ok(())
        }
        other => Err(format!("unknown action {other}, expected write or read")),
    }
}
