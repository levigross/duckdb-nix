# A Rust program, linked against `duckdb`'s libduckdb, finds `extensions` loaded
# without INSTALL or LOAD and uses some of them. The same binary pointed at the
# plain libduckdb must not find them, so the check cannot pass by accident.
{
  pkgs,
  duckdb,
  extensions,
}:

let
  inherit (pkgs) lib;

  # The program is written for the `duckdb` crate of DuckDB 2.0. The state of an older
  # release says which crate goes with it and has the lock file resolved for it
  # (scripts/update.sh).
  example = ../../examples/rust-consumer;
  state = ../../pkgs/duckdb/versions + "/${duckdb.version}";
  crate = (lib.importJSON (state + "/rust-consumer.json")).crate;
  older = builtins.pathExists (state + "/rust-consumer.json");
  olderSrc = pkgs.runCommand "rust-consumer-${duckdb.version}-source" { } ''
    cp -r ${example} $out
    chmod -R u+w $out
    substituteInPlace $out/Cargo.toml --replace-fail '=1.20000.1' '=${crate}'
    cp ${state + "/rust/rust-consumer.Cargo.lock"} $out/Cargo.lock
  '';

  program = pkgs.duckdbRustPlatform.buildRustPackage {
    pname = "rust-consumer";
    version = "0.1.0";
    src = if older then olderSrc else example;
    cargoLock.lockFile =
      if older then state + "/rust/rust-consumer.Cargo.lock" else example + "/Cargo.lock";

    strictDeps = true;

    # libduckdb-sys links this DuckDB, not a bundled copy of its own
    env = {
      DUCKDB_LIB_DIR = "${lib.getLib duckdb}/lib";
      DUCKDB_INCLUDE_DIR = "${lib.getDev duckdb}/include";
    };

    doCheck = false;
  };

  names = lib.escapeShellArgs (map (ext: ext.name) extensions);
in
pkgs.runCommand "rust-consumer-check" { } ''
  export HOME=$TMPDIR

  ${program}/bin/rust-consumer ${names}

  # the same program against a DuckDB without the extensions
  if LD_LIBRARY_PATH=${lib.getLib pkgs.duckdb}/lib ${program}/bin/rust-consumer ${names} >/dev/null 2>&1; then
    echo "the program found the extensions in a DuckDB that has none" >&2
    exit 1
  fi

  touch $out
''
