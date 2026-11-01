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
  craneLib = pkgs.duckdbCraneLib;

  args = {
    pname = "rust-consumer";
    version = "0.1.0";
    src = ../../examples/rust-consumer;

    # vendored in the repository, so evaluation needs no network
    cargoVendorDir = craneLib.vendorCargoDeps { cargoLock = ../../examples/rust-consumer/Cargo.lock; };

    strictDeps = true;

    # libduckdb-sys links this DuckDB, not a bundled copy of its own
    env = {
      DUCKDB_LIB_DIR = "${lib.getLib duckdb}/lib";
      DUCKDB_INCLUDE_DIR = "${lib.getDev duckdb}/include";
    };

    doCheck = false;
  };

  program = craneLib.buildPackage (args // { cargoArtifacts = craneLib.buildDepsOnly args; });

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
