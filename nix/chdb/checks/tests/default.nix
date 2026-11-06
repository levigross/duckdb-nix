# The upstream test suites of chDB, run against the packages of this repository: the Python
# part (chdb-io/chdb), the C examples and the Python tests of chdb-core, and the Rust crate.
# What each one leaves out is said in its own file, with the evidence. The sources are pinned
# in pkgs/chdb/pin.json (scripts/update-chdb.sh).
{ pkgs }:

let
  inherit (pkgs) chdb;
  pin = pkgs.lib.importJSON ../../../../pkgs/chdb/pin.json;
in
{
  rust-tests = import ./rust.nix { inherit pkgs chdb pin; };
}
