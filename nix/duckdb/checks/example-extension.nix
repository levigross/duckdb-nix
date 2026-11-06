# The extension that templates/extension starts from, linked into DuckDB as a
# user of the flake would: it is loaded without INSTALL, and its smoke test passes.
{ pkgs }:

let
  hello = pkgs.callPackage ../../../templates/extension/extension.nix { };
in
import ./all-extensions.nix {
  inherit pkgs;
  duckdb = pkgs.duckdb.withExtensions (_: [ hello ]);
  extensions = [ hello ];
}
