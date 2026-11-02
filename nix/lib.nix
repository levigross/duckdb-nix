# For using this without the overlay: the same `duckdb`, with `withExtensions`,
# built from whichever nixpkgs is given.
{ self, ... }:

{
  flake.lib = {
    duckdb = pkgs: (pkgs.extend self.overlays.default).duckdb;

    # every pinned DuckDB version, by release ("1.4.3") and by line ("1.4")
    duckdbVersions = pkgs: (pkgs.extend self.overlays.default).duckdbVersions;
  };
}
