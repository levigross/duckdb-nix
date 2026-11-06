# chDB, ClickHouse in your process, for Nix

[chDB](https://github.com/chdb-io/chdb-core) is the ClickHouse engine as a library: a C
API (`chdb.h`), a Python module, and bindings for other languages. ClickHouse documents it
as its in-process engine, and its own repository has no embedded-library target (its
`programs/` has only `local`, a program).

This repository packages the upstream's **prebuilt** binaries. Building ClickHouse is a
job of its own (chdb-core is a fork of about a gigabyte of source; by its build script it
needs clang 21 and a nightly Rust, and it has 156 submodules) and is not done here.

| | version | what |
|---|---|---|
| `chdb` | chdb-core 26.9.0 | `libchdb.so` (554 MB), `chdb.h`, `chdb.hpp`, a pkg-config file |
| `python3-chdb` | chdb 4.4.0 on chdb-core 26.9.0 | the Python module, with the engine inside |

```sh
nix build github:levigross/duckdb-nix#chdb
nix build github:levigross/duckdb-nix#python3-chdb
```

with the prefixes `stable-` (26.05) and `previous-` (25.11) for the other nixpkgs. From a
flake of yours, `inputs.<this>.lib.chdb pkgs` is the package of your `pkgs`, and
`(lib.chdb pkgs).pythonModule pkgs.python3Packages` the Python module.

## Where the binaries come from

`libchdb.so` is the release asset `linux-x86_64-libchdb.tar.gz` of
`chdb-io/chdb-core` v26.9.0, and the Python module is two wheels from the same release
and from `chdb-io/chdb` v4.4.0. They are **not signed or attested** by anyone. What
`scripts/update-chdb.sh` does is download each file, compute its hash itself, and fail
unless the release's own `SHA256SUMS` (for the `chdb` wheel, the digest GitHub shows for
the asset) says the same. That is all it proves: the file is the one the release lists.
The hashes are in `pkgs/chdb/pin.json`. The x86_64-linux and aarch64-linux assets are
pinned; only x86_64-linux has been built, and macOS is not offered.

The library needs nothing but the C library (it carries the rest inside; the symbol
versions it uses are no newer than glibc 2.4) and a `RUNPATH` into the upstream's build
directory, which the package removes. The Python module does not use this library: its
wheel carries an engine of its own, from the same release.

The two wheels both ship `chdb/__init__.py`. pip installs `chdb-core` first and `chdb`
over it, and the Python module here unpacks them in that order.

## C and C++

```sh
cc prog.c $(pkg-config --cflags --libs chdb) -o prog
```

```c
#include <chdb.h>
#include <stdio.h>

int main(void) {
  char *args[] = {"prog", NULL};
  chdb_connection *conn = chdb_connect(1, args);
  chdb_result *result = chdb_query(*conn, "SELECT sum(number + 1) FROM numbers(100)", "CSV");
  if (chdb_result_error(result)) { fprintf(stderr, "%s\n", chdb_result_error(result)); return 1; }
  fwrite(chdb_result_buffer(result), 1, chdb_result_length(result), stdout);   /* 5050 */
  chdb_destroy_query_result(result);
  chdb_close_conn(conn);
}
```

The engine starts once per process and one process has one data path: closing the last
connection stops it, and the header says why a host should not do that before it is done
with chDB. `chdb_version()` is the version of chdb-core (`26.9.0`); the engine itself
logs the ClickHouse version it is built from (26.9.2.1).

In the Nix sandbox the engine prints a warning with a stack trace that it cannot find the
cgroup files. It is harmless.

## Python

```python
import chdb
print(chdb.query("SELECT sum(number + 1) FROM numbers(100)", "CSV"))
frame = chdb.query("SELECT number AS n FROM numbers(3)", "DataFrame")
```

pandas and pyarrow are dependencies of the module.

## Rust

The crate is [`chdb-rust`](https://crates.io/crates/chdb-rust) 2.1.0. Its build script
generates the bindings from `chdb.h` and, unless it is told where a library is, downloads
an engine. `examples/chdb-rust-consumer` shows a program that is given ours:

```nix
pkgs.rustPlatform.buildRustPackage {
  # ...
  nativeBuildInputs = [ pkgs.rustPlatform.bindgenHook pkgs.pkg-config ];
  buildInputs = [ pkgs.openssl ];            # see below
  env = {
    CHDB_LIB_DIR = "${chdb}/lib";            # nothing is downloaded
    CHDB_INCLUDE_DIR = "${chdb}/include";
  };
}
```

**OpenSSL or rustls.** The download in the build script is done with `reqwest`, whose
default TLS is OpenSSL. It never runs when `CHDB_LIB_DIR` is set, but the build script is
compiled, so the build needs OpenSSL and `pkg-config` (without them it stops in
`openssl-sys`). That is the `tls = "openssl"` build of `nix/chdb/rust.nix`. For people
who cannot or do not want OpenSSL there is `tls = "rustls"`: the crate, as the lock file
has it with its checksum, is copied, the TLS feature of its `reqwest` is changed to
rustls, and the program is built with that copy as a `[patch.crates-io]` entry and its
own lock file (`Cargo.rustls.lock`). That lock file has no `openssl-sys`, `native-tls` or
`hyper-tls`, which an assertion at evaluation requires, and the build is given neither
`openssl` nor `pkg-config`. The program that comes out is the same in both: the TLS stack
only mattered to the build. `scripts/update-chdb-rust.sh` makes both lock files.

**TLS at run time.** The crate has a feature of its own that needs TLS when the program
runs: `durable-s3`, which keeps a database ("a durable object") in S3 or a store that
speaks its protocol, with `ureq` and **rustls**. The example exposes it as the feature of
the same name and as a mode (`--s3 <url> write|read`).

The crate says it is for engine v26.11.0-rc.2 and is used here with 26.9.0. The calls the
example makes work, including the durable feature; the rest of the crate was not tried.

## Checks

Five for each nixpkgs, named `chdb-<check>` (`stable-chdb-library`, ...). All pass on
unstable, 26.05 and 25.11 on x86_64-linux.

| | |
|---|---|
| `chdb-library` | a C program compiled against the header and linked with `-lchdb`: the library reports the version of the pin, `SELECT sum(...)` is 5050, a Parquet file written by one query is read back by another (499500), a query of a table that does not exist is an error |
| `chdb-python` | the module answers a query, hands a result to pandas, and keeps a table in a session that is opened again; the same script with an interpreter without chdb must fail |
| `chdb-rust-consumer` | the Rust program, built with OpenSSL, runs a query, a Parquet round trip and a wrong query; the same binary with its path to `libchdb` taken out must not start |
| `chdb-rust-consumer-rustls` | the same, built with rustls and no OpenSSL |
| `chdb-rust-consumer-s3` | built with rustls and `durable-s3`: a program writes a table to a durable object in a store (a stand-in for S3, speaking HTTPS with a certificate authority and a certificate it signed) and flushes it; another process, with nothing but the store, reads it back. The same write without the authority in `AWS_CA_BUNDLE` must fail, and the store sees the handshake fail |

The stand-in answers `GET` and `PUT` with `ETag`s and the conditional `If-None-Match: *`
and `If-Match` the protocol uses for its lease; it checks nothing else, and it does not
check signatures. rustls would not accept the self-signed certificate of a certificate
authority as the certificate of the server itself, hence the two certificates.

## Not done

- Building the engine from source, which is what would make it auditable.
- Anything but x86_64-linux with glibc: the aarch64-linux assets are pinned and untried,
  macOS is not offered.
- CPUs without AVX: the upstream's build flags were not read here, and the library was
  only run on machines that have it.
- The other bindings of chDB (Go, Node.js, ...).
