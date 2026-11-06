# The upstream test suites of chDB, run against the packages of this repository: the Python
# part (chdb-io/chdb), the C examples and the Python tests of chdb-core, and the Rust crate.
# What each one leaves out is said in its own file, with the evidence. The sources are pinned
# in pkgs/chdb/pin.json (scripts/update-chdb.sh).
{ pkgs }:

let
  inherit (pkgs) chdb lib;
  pin = lib.importJSON ../../../../pkgs/chdb/pin.json;

  # The Python modules, besides pandas, pyarrow and numpy, that the tests of chdb-core import. A
  # nixpkgs that lacks one of them (25.11 has no adbc-driver-manager) is not offered the check,
  # as a package that a nixpkgs cannot build is not offered there.
  coreModules = [
    "psutil"
    "polars"
    "adbc-driver-manager"
    "deltalake"
    "pymysql"
    "pymongo"
  ];
in
{
  core-c-tests = import ./core-c.nix { inherit pkgs chdb pin; };
  datastore-tests = import ./datastore.nix { inherit pkgs chdb pin; };
  rust-tests = import ./rust.nix { inherit pkgs chdb pin; };
}
// lib.optionalAttrs (lib.all (m: pkgs.python3Packages ? ${m}) coreModules) {
  core-python-tests = import ./core-python.nix {
    inherit pkgs chdb pin;
    modules = coreModules;
  };
}
