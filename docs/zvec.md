# zvec, an in-process vector database, for Nix

[zvec](https://github.com/alibaba/zvec) (Apache-2.0) describes itself as "a lightweight,
lightning-fast, in-process vector database". Here it is packaged as the libraries that the
`vector_search` extension of [NeuG](neug.md) is built on, and for anyone who wants them.

| | |
|---|---|
| `zvec` | the static libraries `libzvec_core.a`, `libzvec_turbo.a`, `libzvec_ailego.a` and `libroaring.a`, and their headers (`include/zvec/{core,ailego,turbo}` and CRoaring's `roaring.h`, `roaring.hh`, `roaring64map.hh`) |

```sh
nix build github:levigross/duckdb-nix#zvec
```

There are also `stable-zvec` and `previous-zvec` (26.05 and 25.11), which have not been built,
and `lib.zvec pkgs` for your own flake. It builds in about a minute on unstable.

**It is not the latest zvec.** The commit is the one that the release of NeuG in this
repository has as its submodule (2026-07-20), because the extension is compiled against
exactly its headers; `scripts/update-zvec.sh` takes it from NeuG's pin, and the NeuG build
fails if the headers it carries differ from this package's. zvec itself is at v0.8.1. What a
newer zvec has, such as its Python module, is not built here.

## How it is built

The same targets and flags as NeuG's own build of zvec (`zvec_core zvec_ailego zvec_turbo
roaring`, static, C++17), as a package of its own instead of a project inside the NeuG build.
Of everything zvec carries, Arrow and RocksDB among it, these four libraries need none: the
rest is configured and not built. The source tree is not a git checkout, so what zvec asks of
one is done in `postPatch`: the patches of three of its thirdparty projects (and the markers
that tell its CMake they are applied), a git version that nothing reads, and `librt`, which
glibc has had inside libc since 2.34.

## Using the libraries

The components of zvec (metrics, storage, index builders) register themselves in static
initializers that nothing refers to. **Link the three zvec libraries with
`-Wl,--whole-archive`**, as NeuG's extension does; linked as ordinary libraries, the
registry is empty and every attempt to make an index fails.

```sh
c++ -std=c++17 -DNDEBUG -I$zvec/include prog.cc -o prog \
  -Wl,--whole-archive $zvec/lib/libzvec_core.a $zvec/lib/libzvec_turbo.a $zvec/lib/libzvec_ailego.a \
  -Wl,--no-whole-archive $zvec/lib/libroaring.a -pthread -ldl -lrt
```

## Checks

`zvec-library` links the libraries that way and uses them for real: a flat
index of 1000 vectors of 8 dimensions must return exactly what brute force returns, an HNSW
index must return the vector itself at distance 0 with the results in ascending order, and a
roaring bitmap is used as a filter. The same program linked as ordinary libraries must fail,
and it does, because the registry of components is empty.

The document count of an index (`GetDocCount()`) is twice the number of vectors added, for
both kinds of index. The searches show that nothing is stored twice, so the count is printed
by the check and not asserted. Why it is twice was not looked into.

## Not done

- A newer zvec than NeuG's, and its Python and C bindings.
- Any system but x86_64-linux with glibc, and any nixpkgs but unstable.
