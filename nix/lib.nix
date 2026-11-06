# For using this without the overlay: an engine of this flake, built from whichever
# nixpkgs is given.
{ self, ... }:

{
  flake.lib = {
    # DuckDB, with `withExtensions`
    duckdb = pkgs: (pkgs.extend self.overlays.default).duckdb;

    # every pinned DuckDB version, by release ("1.4.3") and by line ("1.4")
    duckdbVersions = pkgs: (pkgs.extend self.overlays.default).duckdbVersions;

    # chDB, ClickHouse in your process: libchdb with its header, and `pythonModule`
    chdb = pkgs: (pkgs.extend self.overlays.default).chdb;
  };
}
