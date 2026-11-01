# DuckDB with extensions, for Nix

DuckDB's extensions linked into DuckDB itself, so the CLI, `libduckdb` and its
users get them with no `INSTALL`, no signature check and no extension directory.

nixpkgs' `duckdb` builds only the extensions in DuckDB's own tree. Everything else
(`httpfs`, `spatial`, `iceberg`, ...) has to be downloaded at runtime as a signed
binary, which does not suit Nix, a sandbox, or a library that is linked rather than run.

Status: DuckDB 2.0.0, x86_64-linux with glibc. 24 of the 25 out-of-tree extensions
link and pass their checks on nixpkgs unstable, and most of them on the two latest
stable releases (see [nixpkgs versions](#nixpkgs-versions)). See also
[Not done](#not-done).

```nix
duckdb.withExtensions (e: [ e.httpfs e.spatial ])
```

```sh
nix build .#duckdb-all        # all 24
nix build .#duckdb-httpfs     # one
nix build .#duckdb            # none: DuckDB 2.0.0 as nixpkgs would build it
nix build .#stable-duckdb-all    # all it can, on the current stable nixpkgs (26.05)
nix build .#previous-duckdb-all  # and on the one before (25.11)
nix flake check
```

## nixpkgs versions

The flake pins `nixos-unstable`, `nixos-26.05` and `nixos-25.11`. Every package and
check exists for each, the older two behind a `stable-` and a `previous-` prefix, and
the overlay works on whichever nixpkgs you apply it to.

| nixpkgs | extensions in `duckdb-all` | not available |
|---|---|---|
| unstable | 24 | |
| 26.05 | 23 | spatial: its sources need GDAL 3.13, nixpkgs has 3.12 |
| 25.11 | 22 | spatial (GDAL 3.11), azure (nixpkgs has no Azure SDK) |

An extension that a nixpkgs cannot build says why when you ask for it, and is left
out of `duckdb-all` and the checks. Nothing is backported; the answer is a newer nixpkgs.

## The extensions

| | |
|---|---|
| no dependencies | encodings, fts, inet, legacy_parser, sqlsmith, sqlite_scanner, vss, duckpgq |
| system libraries | httpfs, quack, excel, aws, glue, azure, ducklake, iceberg, avro, unity_catalog, postgres_scanner, mysql_scanner, spatial |
| Rust | lance, delta, vortex |
| cannot be linked | odbc_scanner (a C API extension, loadable at runtime only) |

Each is the commit the DuckDB release pins in `.github/config/extensions/`. The
exception is duckpgq (SQL/PGQ graph queries), a community extension: its commit is
the one the `duckdb/community-extensions` descriptor names, and the update script
refuses it unless the DuckDB it was developed against is this release. From DuckDB 2.0
its syntax is switched on with `SET active_grammar_extensions = ['duckpgq']`.
Asking for an extension that needs another gets it too (`iceberg` brings `avro` and `httpfs`).

## How it works

- `scripts/update.sh [tag]` computes every pin from an upstream release: DuckDB's
  commit and hash, each extension's commit and hash, the submodules they need, the
  Rust lock files and the hashes of their git dependencies. Nothing is copied from
  another repository.
- Each extension's source is its own small derivation (`source-<name>`): the pin,
  its submodules, DuckDB's own patches for it and ours. A patch that stops applying
  fails in seconds, not after a DuckDB build.
- `pkgs/duckdb` overrides nixpkgs' `duckdb` and links the selection. The link order
  is the load order, so the in-tree extensions come first and dependencies before
  their users.
- The build without extensions keeps the same derivation as nixpkgs' would, so it
  is not rebuilt when this machinery changes.

### The Rust extensions

lance, delta and vortex build their Rust half by running cargo from CMake, which
needs the network. Here it is a separate derivation (`rust-<name>`) built by
nixpkgs' `rustPlatform` from a `Cargo.lock` kept in the repository. Evaluating the
flake never builds or fetches anything, so it works with
`allow-import-from-derivation = false`, as Hydra requires.

- They use the official 1.99.1 toolchain from `rust-overlay`. nixpkgs' `rustc` is
  linked against LLVM 21 while its standard library declares AVX-512 intrinsics for
  LLVM 22, and `lance-linalg` does not compile with it.
- Several Rust static libraries cannot be linked together, since each carries its
  own `std`. The symbols more than one defines are renamed per library
  (`pkgs/duckdb/isolate-rust.nix`), which gives each a private `std` as a loadable
  extension would have.
- vortex needed more: the `Cargo.lock` upstream commits disagrees with its own
  `Cargo.toml` (the update script re-resolves it), crates that take the workspace's
  README as their documentation find none in the vendor directory, and the build
  script regenerates a header with a tool that needs the monorepo layout. It uses the committed header,
  which upstream regenerates on every build; the smoke test is there to catch it lagging.

## Checks

| | |
|---|---|
| `extension-pins` | every extension is the commit its source names (DuckDB's configuration, run as CMake, or a community descriptor, read as YAML), and every extension DuckDB configures is packaged |
| `httpfs` | reads a CSV over HTTP; the same query fails on plain DuckDB |
| `all-extensions` | every extension is loaded without `INSTALL`, and each passes an offline smoke test (real round trips for vortex, lance and delta; a failed connection from libpq and MariaDB) |
| `rust-consumer` | a Rust program using the `duckdb` crate, linked against `libduckdb`, finds the extensions; the same binary against plain DuckDB does not |

Counting what is loaded is the check that matters. CMake carries on without an
extension it could not build, and says so in a line that is easy to miss.

DuckDB's own test suite runs in `installCheckPhase`, as in nixpkgs. Some tests cannot
pass in this build, and each is listed with its reason in the build log (and in
`pkgs/duckdb/extensions/default.nix`): tests that need the network, tests that assert
an extension is absent, and C++ tests that cannot run with `postgres_scanner` or
`spatial` loaded. Tests that need something different run in their own invocation instead.

## Developing

- `dev-keep-going` builds everything without the test suite; `dev-check` and
  `dev-rust-check` run the checks against it; `dev-configure` stops after CMake.
- For tests, build `unittest` once in a directory you keep (`nix develop .#duckdb-all`,
  then unpack, patch, configure and `ninja test/unittest`), and rerun single tests
  or relink with a subset of the extensions in a minute. That is how the test
  failures were attributed to individual extensions.
- Flakes see only tracked files; stage new ones.

## Not done

- Python. `python3Packages.duckdb` builds its own copy of DuckDB and needs the same
  extension list. nixpkgs' module is written for pybind11 and a custom build
  backend, and duckdb-python 2.0.0 uses nanobind, so it needs a port.
- Fully static (`pkgsStatic`, musl) builds.
- Other platforms. Only x86_64-linux has been built; aarch64-linux and
  aarch64-darwin are untried.
- Size: `libduckdb.so` with all 24 is 909 MB, mostly lance's DataFusion stack. Link
  only what you use.
