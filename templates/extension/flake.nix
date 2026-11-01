{
  description = "A DuckDB extension, linked into DuckDB";

  inputs = {
    duckdb-nix.url = "github:levigross/duckdb-nix";
    nixpkgs.follows = "duckdb-nix/nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      duckdb-nix,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      forAllSystems =
        f:
        lib.genAttrs [
          "x86_64-linux"
          "aarch64-linux"
          "aarch64-darwin"
        ] (system: f nixpkgs.legacyPackages.${system});

      # nixpkgs' duckdb, with the extensions of duckdb-nix and `mkExtension`
      duckdbFor = pkgs: duckdb-nix.lib.duckdb pkgs;

      extensionFor = pkgs: pkgs.callPackage ./extension.nix { duckdb = duckdbFor pkgs; };

      # DuckDB with the extension linked in: no INSTALL, no LOAD
      duckdbWithExtension = pkgs: (duckdbFor pkgs).withExtensions (_: [ (extensionFor pkgs) ]);
    in
    {
      packages = forAllSystems (pkgs: {
        default = duckdbWithExtension pkgs;
      });

      checks = forAllSystems (pkgs: {
        default = pkgs.runCommand "duckdb-hello-check" { } ''
          ${lib.getExe (duckdbWithExtension pkgs)} -no-agent -bail -c ${lib.escapeShellArg (extensionFor pkgs).smoke.sql}
          touch $out
        '';
      });
    };
}
