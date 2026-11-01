{ lib, duckdb }:

duckdb.mkExtension {
  # as in CMakeLists.txt and src/hello_extension.cpp
  name = "hello";
  version = "0.1.0";

  # only what the build needs, so that editing this file or flake.nix does not rebuild DuckDB
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./CMakeLists.txt
      ./src
    ];
  };

  # Libraries the extension uses go in buildInputs, and CMake finds them as it
  # does for any project: `buildInputs = [ openssl ];` for find_package(OpenSSL).

  # What must work in a DuckDB that has the extension. `nix flake check` runs it.
  smoke = "SELECT CASE WHEN hello('Nix') = 'Hello, Nix!' THEN 1 ELSE error('hello') END";
}
