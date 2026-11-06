# NeuG, an embedded graph database, for Nix

[NeuG](https://github.com/alibaba/neug) (Apache-2.0, from the GraphScope team at Alibaba) is a
graph database that runs inside your process and is queried in Cypher. It has Python and
Node.js packages upstream, and a C++ library with no C API. This repository builds it from
source, version 0.3.0, with every extension it has.

| | |
|---|---|
| `neug` | `libneug.so`, its headers, the CMake package, and the six extensions |
| `neug-nodejs` | the addon for Node.js (`neug.nodejs`, the second output of `neug`) |
| `zvec` | the libraries behind the `vector_search` extension, a [package of its own](zvec.md) |

```sh
nix build github:levigross/duckdb-nix#neug
nix build github:levigross/duckdb-nix#neug-nodejs
```

`lib.neug pkgs` is the package of your own `pkgs`. It builds in about 6 minutes on a machine
with 20 cores given to it, and in 16 on a builder with 56 (why the larger machine was slower
was not looked into). Only unstable has been built.

## Extensions

`parquet`, `pattern_matching`, `gds`, `httpfs`, `fts` and `vector_search`. NeuG has no way to
link them in: each is a shared library, `lib/extension/<name>/lib<name>.neug_extension`, that
`LOAD <name>` opens. Upstream gets them with `INSTALL`, from a bucket on Alibaba's cloud. Here
the directory they are looked for in is built into `libneug.so` as the prefix of the package,
so `LOAD` finds them with no `INSTALL`, no download and no environment (the environment
variable `NEUG_EXTENSION_HOME_PYENV` still overrides it).

## C++

```cmake
find_package(neug REQUIRED)
add_executable(app app.cc)
target_include_directories(app PRIVATE ${NEUG_INCLUDE_DIRS})
target_link_libraries(app PRIVATE ${NEUG_LIBRARIES})
```

with `buildInputs = [ neug ];`. The CMake package finds ZLIB, OpenSSL, abseil and protobuf, so
the first two are propagated and the others are in the package. It also defines
`NEUG_WITH_MIMALLOC`, `ENABLE_CHRONO_YMD` and `NDEBUG` for you: the headers branch on them,
and a program without them disagrees with the library about the layout of its types (upstream
exports none of the three).

```cpp
#include <neug/neug.h>

neug::NeugDB db;
db.Open("");                       // in memory
auto conn = db.Connect();
conn->Query("CREATE NODE TABLE person(id INT64, name STRING, PRIMARY KEY(id));");
// Query gives an expected: it is false on error, and .value() is the result
auto result = conn->Query("MATCH (n:person) RETURN n.name;").value();
while (result.hasNext()) {         // the cursor starts on the first row
  std::cout << result.GetString(0) << "\n";
  result.next();
}
```

## Node.js

With `NODE_PATH` set to `lib/node_modules` of the `nodejs` output of `neug` (`neug-nodejs`):

```js
const { Database } = require('neug');
const db = new Database({ databasePath: '', mode: 'w' });
const conn = db.connect();
conn.execute('LOAD parquet');
const rows = [...conn.execute('MATCH (n:person) RETURN n.id, n.name;')];  // an INT64 is a BigInt
```

## What the build needed

NeuG wants a git checkout and an ordinary Linux, and the sandbox has neither:

- Five patches of its submodules are applied with `git apply`, which does nothing outside a
  checkout. They are applied in `postPatch`; the helper it uses for the others falls back to
  `patch`.
- brpc defines `__STRICT_ANSI__` itself, which with GNU mode makes `libstdc++` of GCC 16
  define its `__int128` traits twice (296 failures of one cause). yaml-cpp lacks `<cstdint>`.
  brpc has scripts that name `/usr/bin/env`, and its `.pc` file needs relative install
  directories.
- carquet, which `parquet` links, compiles its C with `-flto=auto`, and the plain `ar` of Nix
  makes no index of such objects: the linker took nothing from the archive and the extension
  would not load (`undefined symbol: carquet_reader_close`). Debian's `ar` loads the plugin by
  itself, which is why upstream does not see it. LTO is turned off for carquet.
- The directory `LOAD` looks in is the output directory of the build, which is gone once
  installed; `NEUG_EXTENSION_HOME` sets it instead.
- The addon for Node.js asks `node` for the headers of `node-addon-api`, which npm would
  fetch; the version its lock file names is pinned, with the hash the lock records.

## Checks

| | |
|---|---|
| `neug-library` | a program is built through the installed CMake package, loads each of the six extensions by name, runs a two-hop query and a wrong one; `LOAD` must fail when the extension directory is pointed at an empty one |
| `neug-nodejs` | the addon runs in the `node` of nixpkgs: an in-memory database, the six extensions, the two-hop query, a wrong query that throws; without the package on the path of `node`, `require('neug')` must fail |

## Not done

- The Python module and Rust bindings (in progress).
- The test suites of NeuG itself (C++, Python, Node.js) were not run.
- The service mode (`db.serve()`, an HTTP server) is built and was not tried.
- `httpfs` loads; reading over the network was not tried, as the sandbox has none.
- Other nixpkgs than unstable, and any system but x86_64-linux with glibc.
- The engine can stop the process on some input: its source has about 160 `CHECK` and
  `LOG(FATAL)` sites in 43 files (a count by `grep`; none was exercised).
