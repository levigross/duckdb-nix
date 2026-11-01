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
        lib.genAttrs
          [
            "x86_64-linux"
            "aarch64-linux"
            "aarch64-darwin"
          ]
          (
            system:
            f (
              import nixpkgs {
                inherit system;
                overlays = [ duckdb-nix.overlays.default ];
              }
            )
          );

      extensionFor = pkgs: pkgs.callPackage ./extension.nix { };

      # DuckDB with the extension linked in: no INSTALL, no LOAD
      duckdbFor = pkgs: pkgs.duckdb.withExtensions (_: [ (extensionFor pkgs) ]);
    in
    {
      packages = forAllSystems (pkgs: {
        default = duckdbFor pkgs;
      });

      checks = forAllSystems (pkgs: {
        default = pkgs.runCommand "duckdb-hello-check" { } ''
          ${lib.getExe (duckdbFor pkgs)} -no-agent -bail -c ${lib.escapeShellArg (extensionFor pkgs).smoke.sql}
          touch $out
        '';
      });
    };
}
