# For using this without the overlay: the same `duckdb`, with `withExtensions`,
# built from whichever nixpkgs is given.
{ self, ... }:

{
  flake.lib.duckdb = pkgs: (pkgs.extend self.overlays.default).duckdb;
}
