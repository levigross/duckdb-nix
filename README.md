# DuckDB with extensions, for Nix

DuckDB extensions linked into DuckDB itself, so the CLI, Python and Rust all
get them without `INSTALL`, signature checks or an extension directory.

Status: prototype. Only `httpfs` on glibc, DuckDB 2.0.0.

```nix
duckdb.withExtensions (e: [ e.httpfs ])
```

```sh
nix build .#duckdb-httpfs
nix flake check
```

## Layout

- `pkgs/duckdb/` overrides nixpkgs' `duckdb` to 2.0.0 and links the selected extensions in.
- `pkgs/duckdb/extensions/` extension definitions. `pins.json` holds the commits
  the DuckDB release pins in `.github/config/extensions/`; `checks.nix` fails if they drift.
- `checks.nix` proves an extension works (httpfs reads a CSV over HTTP, and the same
  query fails without it).

## Not done yet

Python (`python3Packages.duckdb` builds its own DuckDB), Rust (`DUCKDB_LIB_DIR`),
the other extensions, and fully static (`pkgsStatic`) builds.
