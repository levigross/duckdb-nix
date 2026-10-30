//! Opens DuckDB through libduckdb and checks that extensions are there without
//! INSTALL or LOAD: first that the ones named on the command line are loaded,
//! then that a few of them do their job.

use duckdb::{Connection, Result};

fn scalar(conn: &Connection, sql: &str) -> Result<String> {
    conn.query_row(sql, [], |row| row.get(0))
}

fn main() -> Result<()> {
    let conn = Connection::open_in_memory()?;
    let expected: Vec<String> = std::env::args().skip(1).collect();

    let loaded: Vec<String> = conn
        .prepare("SELECT extension_name FROM duckdb_extensions() WHERE loaded ORDER BY 1")?
        .query_map([], |row| row.get(0))?
        .collect::<Result<_>>()?;
    println!("DuckDB {}", scalar(&conn, "SELECT version()")?);
    println!("loaded: {}", loaded.join(", "));

    let missing: Vec<&String> = expected.iter().filter(|name| !loaded.contains(name)).collect();
    if !missing.is_empty() {
        eprintln!("expected but not loaded: {missing:?}");
        std::process::exit(1);
    }

    // only checked for the extensions that were asked for
    let wants = |name: &str| expected.iter().any(|e| e == name);

    if wants("spatial") {
        let point = scalar(&conn, "SELECT ST_AsText(ST_Point(1, 2))")?;
        assert_eq!(point, "POINT (1 2)");
        println!("spatial: {point}");
    }

    if wants("sqlite_scanner") {
        conn.execute_batch(
            "ATTACH ':memory:' AS s (TYPE sqlite);
             CREATE TABLE s.t(i INTEGER);
             INSERT INTO s.t VALUES (41), (1);",
        )?;
        let sum = scalar(&conn, "SELECT sum(i)::VARCHAR FROM s.t")?;
        assert_eq!(sum, "42");
        println!("sqlite_scanner: sum = {sum}");
    }

    if wants("vortex") {
        let file = std::env::temp_dir().join(format!("rust-consumer-{}.vortex", std::process::id()));
        let path = file.display();
        conn.execute_batch(&format!(
            "COPY (SELECT i AS id FROM range(1000) t(i)) TO '{path}' (FORMAT vortex)"
        ))?;
        let sum = scalar(&conn, &format!("SELECT sum(id)::VARCHAR FROM read_vortex('{path}')"))?;
        std::fs::remove_file(&file).ok();
        assert_eq!(sum, "499500");
        println!("vortex: round trip sum = {sum}");
    }

    println!("ok");
    Ok(())
}
