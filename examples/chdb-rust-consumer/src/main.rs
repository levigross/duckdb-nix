//! A Rust program linked against libchdb. It runs a query, writes a Parquet file and reads
//! it back, and expects a wrong query to be an error. It exits with a non-zero status when
//! anything is not as expected.

use chdb_rust::arg::Arg;
use chdb_rust::error::Error;
use chdb_rust::execute;
use chdb_rust::format::OutputFormat;

fn query(sql: &str) -> Result<String, Error> {
    let result = execute(sql, Some(&[Arg::OutputFormat(OutputFormat::CSV)]))?;
    Ok(result.data_utf8_lossy().trim().to_string())
}

fn expect(what: &str, got: Result<String, Error>, want: &str) -> bool {
    match got {
        Ok(value) if value == want => {
            println!("{what}: {value}");
            true
        }
        Ok(value) => {
            eprintln!("{what}: expected {want}, got {value}");
            false
        }
        Err(error) => {
            eprintln!("{what}: {error}");
            false
        }
    }
}

fn main() {
    let dir = std::env::temp_dir().join(format!("chdb-rust-consumer-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("a directory for the Parquet file");
    let parquet = dir.join("t.parquet");
    let parquet = parquet.to_str().expect("a path");

    let mut ok = true;

    ok &= expect("sum of 1 to 100", query("SELECT sum(number + 1) FROM numbers(100)"), "5050");

    ok &= query(&format!(
        "INSERT INTO FUNCTION file('{parquet}', Parquet) SELECT number AS n FROM numbers(1000)"
    ))
    .is_ok();
    ok &= expect(
        "sum read back from Parquet",
        query(&format!("SELECT sum(n) FROM file('{parquet}', Parquet)")),
        "499500",
    );

    match query("SELECT * FROM no_such_table") {
        Err(Error::QueryError(message)) if message.contains("no_such_table") => {
            println!("a wrong query is an error: {}", message.lines().next().unwrap_or(""));
        }
        other => {
            eprintln!("a wrong query was not the expected error: {other:?}");
            ok = false;
        }
    }

    let _ = std::fs::remove_dir_all(&dir);
    std::process::exit(if ok { 0 } else { 1 });
}
