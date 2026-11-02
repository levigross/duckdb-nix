# DuckDB with extensions, for Nix

DuckDB's extensions linked into DuckDB itself, so the CLI, `libduckdb` and its
users get them with no `INSTALL`, no signature check and no extension directory.

nixpkgs' `duckdb` builds only the extensions in DuckDB's own tree. Everything else
(`httpfs`, `spatial`, `iceberg`, ...) has to be downloaded at runtime as a signed
binary, which does not suit Nix, a sandbox, or a library that is linked rather than run.

Status: DuckDB 2.0.0, x86_64-linux with glibc. 28 of the 29 out-of-tree extensions
link and pass their checks on nixpkgs unstable, and most of them on the two latest
stable releases (see [nixpkgs versions](#nixpkgs-versions)). The DuckDB that each of
those ships, 1.5.2 and 1.4.3, is available too, with the extensions its release has
(see [DuckDB versions](#duckdb-versions)). See also [Not done](#not-done).

## Using it

### Try it

There is a package for each extension, and `nix flake show` lists them:

```sh
nix run github:levigross/duckdb-nix#duckdb-spatial
nix shell github:levigross/duckdb-nix#duckdb-httpfs
nix build github:levigross/duckdb-nix#duckdb-all    # all 28
```

For 26.05 and 25.11 the names carry a prefix: `#stable-duckdb-spatial`,
`#previous-duckdb-all`. An extension that a nixpkgs cannot build has no package there.
`#duckdb` is DuckDB 2.0.0 with none, as nixpkgs would build it.

The other DuckDB versions have the line in the name: `#duckdb-1_4-httpfs`,
`#previous-duckdb-1_4-all`, `#stable-duckdb-1_5-all` (see
[DuckDB versions](#duckdb-versions)).

### In your flake

`lib.duckdb` takes your package set and gives back `duckdb` with `withExtensions`. It
changes nothing else in `pkgs`, which makes it the way to start:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    duckdb-nix.url = "github:levigross/duckdb-nix";
    duckdb-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, duckdb-nix, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      duckdb = duckdb-nix.lib.duckdb pkgs;
    in
    {
      packages.x86_64-linux.default = duckdb.withExtensions (e: [
        e.httpfs
        e.spatial
      ]);

      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = [ (duckdb.withExtensions (e: [ e.httpfs ])) ];
      };
    };
}
```

`follows` makes the flake's own packages (`duckdb-nix.packages.<system>.duckdb-httpfs`)
build with your nixpkgs too. That matters when something links `libduckdb`, since a
program built with one glibc cannot load a library built with a newer one. With
flake-parts it is the same call in `perSystem`:

```nix
perSystem = { pkgs, ... }: {
  packages.default = (inputs.duckdb-nix.lib.duckdb pkgs).withExtensions (e: [ e.zipfs ]);
};
```

### A different DuckDB version

DuckDB 2.0.0 is the default. The DuckDB that nixpkgs 26.05 and 25.11 ship, 1.5.2 and
1.4.3, can have the extensions too. Ask for the line (`"1.5"`, `"1.4"`) or the release
(`"1.5.2"`, `"1.4.3"`; they are the same build):

```nix
let
  duckdbs = duckdb-nix.lib.duckdbVersions pkgs; # as lib.duckdb is, for every version
  duckdb = duckdbs."1.4";                       # 1.4.3; duckdb.version says which
in
duckdb.withExtensions (e: [ e.httpfs e.spatial ])
```

| | |
|---|---|
| flake | `duckdb-nix.lib.duckdbVersions pkgs` as above; `lib.duckdb pkgs` is still 2.0.0 |
| overlay | `pkgs.duckdbVersions."1.4"`; `pkgs.duckdb` is still 2.0.0 |
| command line | `nix shell github:levigross/duckdb-nix#duckdb-1_4-httpfs`, or `#previous-duckdb-1_4-all` to build it with nixpkgs 25.11 (`#stable-duckdb-1_5-all` for 1.5 with 26.05) |
| Rust or C++ | `lib.getLib duckdb` and `lib.getDev duckdb` of the one you chose, as in [From Rust or C++](#from-rust-or-c); the `duckdb` crate must be the one for that DuckDB |

`map (e: e.name) duckdb.linkableExtensions` lists what that version can link with your
nixpkgs. An extension its release does not have fails with a message that says so, not
with an evaluation error. What differs from 2.0, and what has been built and tested, is
in [DuckDB versions](#duckdb-versions).

### NixOS and home-manager

```nix
{ pkgs, ... }:
{
  environment.systemPackages = [
    ((duckdb-nix.lib.duckdb pkgs).withExtensions (e: [ e.httpfs e.spatial ]))
  ];
}
```

The same expression goes in `home.packages` for home-manager.

### As an overlay

```nix
import nixpkgs { inherit system; overlays = [ duckdb-nix.overlays.default ]; }
# or, in a NixOS configuration: nixpkgs.overlays = [ duckdb-nix.overlays.default ];
```

then `pkgs.duckdb.withExtensions (e: [ ... ])` as above. This replaces `pkgs.duckdb` for
everything that uses it, which has a cost: `python3Packages.duckdb` no longer evaluates
(see [Not done](#not-done)). Prefer `lib.duckdb` unless you want that replacement.

### From Rust or C++

`libduckdb` has the extensions linked in, so a program that links it has them without
`INSTALL` or `LOAD`. For the `duckdb` crate, point it at this build:

```nix
rustPlatform.buildRustPackage {
  # ...
  env = {
    DUCKDB_LIB_DIR = "${lib.getLib duckdb}/lib";
    DUCKDB_INCLUDE_DIR = "${lib.getDev duckdb}/include";
  };
}
```

with `duckdb = { version = "=1.20000.1", default-features = false }` in `Cargo.toml`.
`examples/rust-consumer` is that program, and the `rust-consumer` check builds it. For
[an extension of your own](#your-own-extension) the same `withExtensions` takes it.

Nothing is cached yet, so the first build of a selection compiles DuckDB and runs its
test suite. For a quick look, `.overrideAttrs { doInstallCheck = false; }` leaves the
suite out.

## nixpkgs versions

The flake pins `nixos-unstable`, `nixos-26.05` and `nixos-25.11`. Every package and
check exists for each, the older two behind a `stable-` and a `previous-` prefix, and
the overlay works on whichever nixpkgs you apply it to.

| nixpkgs | extensions in `duckdb-all` | not available |
|---|---|---|
| unstable | 28 | |
| 26.05 | 27 | spatial: its sources need GDAL 3.13, nixpkgs has 3.12 |
| 25.11 | 26 | spatial (GDAL 3.11), azure (nixpkgs has no Azure SDK) |

An extension that a nixpkgs cannot build says why when you ask for it, and is left
out of `duckdb-all` and the checks. Nothing is backported; the answer is a newer nixpkgs.

## DuckDB versions

2.0.0 is the default, and [another is asked for](#a-different-duckdb-version) by its
line or release. A line has one pinned release, the one nixpkgs ships, and a project
gets the one in the `flake.lock` of its `duckdb-nix` input.

| DuckDB | ships in | pinned extensions | status |
|---|---|---|---|
| 2.0.0 | | 29 | built with DuckDB's own test suite and every check on all three nixpkgs |
| 1.5.2 | nixpkgs 26.05 | 20 | built with DuckDB's own test suite and every check on 26.05 |
| 1.4.3 | nixpkgs 25.11 | 18 | built with DuckDB's own test suite and every check on 25.11 |

For 1.5.2 on 26.05 and 1.4.3 on 25.11, DuckDB is built with all the extensions this
nixpkgs can build for the release and passes its own test suite, apart from the one
test that attaches a database over HTTP, which needs network access. The
`extension-pins` check (each pin is the commit the release's own configuration
names), the `httpfs` check (the suite) and the `all-extensions` check (every
extension is loaded without `INSTALL`, and its smoke test passes) pass. The other
combinations are not built yet.

What differs from 2.0, since each release configures its own extensions:

- **Not in the release:** `lance` before 1.4.5 (so not in 1.4.3), `odbc_scanner`
  before 1.5, `quack` before 1.5.5, `glue` and `legacy_parser` before 2.0. Asking for
  one says so.
- **Not packaged yet:** `vortex`, whose Rust is a git submodule until 1.5.5 and needs
  its own packaging, and the community extensions, whose releases for these versions
  are not pinned. Both say so when asked for.
- **spatial** for 1.4 uses the file handle interface of GDAL before 3.13, so it builds
  with the GDAL of nixpkgs 25.11 and 26.05, and not with unstable's. For 1.5 and 2.0
  it is the other way round.
- **avro and mysql_scanner** link nixpkgs' libraries instead of the ones vcpkg builds
  for the release, and **delta** builds delta-kernel-rs at the release the extension
  names, with the lock file that this repository generates (the kernel does not commit
  one before 0.21).
- The check with a Rust program is for 2.0 only: which `duckdb` crate goes with 1.4.3
  and 1.5.2 is not established.

Only the version a nixpkgs ships is built and tested on that nixpkgs. The other
combinations evaluate, and CMake configures the two that are tested; the rest are not
built.

## The extensions

| | |
|---|---|
| no dependencies | encodings, fts, inet, legacy_parser, sqlsmith, sqlite_scanner, vss, duckpgq, psql, sheetreader |
| system libraries | httpfs, quack, excel, aws, glue, azure, ducklake, iceberg, avro, unity_catalog, postgres_scanner, mysql_scanner, spatial, zipfs, webbed |
| Rust | lance, delta, vortex |
| cannot be linked | odbc_scanner (a C API extension, loadable at runtime only) |

Each is the commit the DuckDB release pins in `.github/config/extensions/`. The
exceptions are community extensions: duckpgq (SQL/PGQ graph queries), psql (a pipe
syntax), sheetreader (fast XLSX reading), webbed (XML and HTML) and zipfs (files inside
zip and other archives). Their commit is the one the `duckdb/community-extensions`
descriptor names, and the update script refuses it unless the DuckDB it was developed
against is this release. A descriptor is not proof that the extension is there, though:
for DuckDB 2.0 the Query.Farm ones (datasketches, hashfuncs, crypto, ...) are stubs that
load a build from Query.Farm's own repository, so none of them is packaged.

Some of these need switching on, since from DuckDB 2.0 a grammar is per connection:
duckpgq with `SET active_grammar_extensions = ['duckpgq']`, and psql with
`CALL psql_enable()` in the shell, which sets its own grammar. A program that links
`libduckdb` has psql on in every connection.

Asking for an extension that needs another gets it too (`iceberg` brings `avro` and `httpfs`).

## How it works

- `scripts/update.sh [tag]` computes every pin from an upstream release into `pkgs/duckdb/versions/<version>/`, one directory for each DuckDB version: DuckDB's
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

## Your own extension

```sh
nix flake init -t github:levigross/duckdb-nix#extension
nix build
./result/bin/duckdb -c "SELECT hello('Nix')"
```

The template is a small extension in C++ (`hello(name)`) and a flake that links it into
DuckDB with `duckdb-nix.lib.duckdb`. `duckdb.mkExtension` takes the source directory,
which has a `CMakeLists.txt` as in [DuckDB's extension template](https://github.com/duckdb/extension-template),
and the libraries it needs in `buildInputs`. `withExtensions` then links it like the
packaged ones: `duckdb.withExtensions (e: [ e.httpfs hello ])`. DuckDB's own test
suite runs on the result, as it does for the others.

## Checks

| | |
|---|---|
| `extension-pins` | every extension is the commit its source names (DuckDB's configuration, run as CMake, or a community descriptor, read as YAML), and every extension DuckDB configures is packaged |
| `httpfs` | reads a CSV over HTTP; the same query fails on plain DuckDB |
| `all-extensions` | every extension is loaded without `INSTALL`, and each passes an offline smoke test (real round trips for vortex, lance and delta; a failed connection from libpq and MariaDB) |
| `rust-consumer` | a Rust program using the `duckdb` crate, linked against `libduckdb`, finds the extensions; the same binary against plain DuckDB does not |
| `<check>-1_4`, `<check>-1_5` | `extension-pins`, `httpfs` and `all-extensions` for the DuckDB that nixpkgs 25.11 and 26.05 ship, on that nixpkgs (`previous-all-extensions-1_4`, `stable-all-extensions-1_5`) |
| `example-extension` | the extension of `templates/extension` is linked into DuckDB as a user of the flake would, is loaded without `INSTALL`, and passes its smoke test (on unstable only, since the mechanism is the same for every nixpkgs) |

Counting what is loaded is the check that matters. CMake carries on without an
extension it could not build, and says so in a line that is easy to miss.

The checks above build DuckDB several times, each with its test suite: about two hours
with 12 cores for all three nixpkgs. A free hosted GitHub runner has 4 cores and a
six-hour limit, so run them yourself with `nix flake check`. GitHub Actions
(`.github/workflows/ci.yml`) runs what does not need a DuckDB build: style, evaluation
for every system without import from derivation, every extension's source and the pins
check, and CMake configuring DuckDB for each nixpkgs and for the DuckDB it ships.

DuckDB's own test suite runs in `installCheckPhase`, as in nixpkgs. Some tests cannot
pass in this build, and each is listed with its reason in the build log (and in
`pkgs/duckdb/extensions/default.nix`): tests that need the network, tests that assert
an extension is absent, and C++ tests that cannot run with `postgres_scanner` or
`spatial` loaded, or with `psql` linked (it switches its grammar on in every connection). Tests that need something different run in their own invocation instead.

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
  backend, and duckdb-python 2.0.0 uses nanobind, so it needs a port. Until then it
  does not evaluate with the overlay (which removes the hash it needs, since a Python
  module for another DuckDB version would be wrong), and `lib.duckdb` leaves it alone.
  For 1.4.3 and 1.5.2 no port is needed, since nixpkgs' module is that version and
  pybind11 is what it uses, but it still builds its own DuckDB, which has to be given
  the extensions: not done either.
- vortex for 1.4 and 1.5 (its Rust is a git submodule before 1.5.5), and the community
  extensions for them (only zipfs, and psql for 1.5.2, have a release that matches).
- Fully static (`pkgsStatic`, musl) builds.
- Other platforms. Only x86_64-linux has been built; aarch64-linux and
  aarch64-darwin are untried.
- Size: `libduckdb.so` with all 28 is 911 MB, mostly lance's DataFusion stack. Link
  only what you use.

## License

[Apache-2.0](LICENSE) for the Nix code and scripts in this repository. DuckDB, the
extensions and the Rust crates it builds are not part of it and keep their own
licenses.
