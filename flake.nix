{
  description = "DuckDB with extensions linked in, for the CLI, Python and Rust";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              overlays = [ self.overlays.default ];
            }
          )
        );

      linkable = pkgs: pkgs.lib.filter (ext: ext.linkable) (pkgs.lib.attrValues pkgs.duckdb.extensions);
    in
    {
      overlays.default = final: prev: {
        duckdb = final.callPackage ./pkgs/duckdb { duckdb = prev.duckdb; };
      };

      packages = forAllSystems (
        pkgs:
        let
          all = pkgs.duckdb.withExtensions (_: linkable pkgs);
        in
        {
          default = pkgs.duckdb;
          duckdb = pkgs.duckdb;
          duckdb-httpfs = pkgs.duckdb.withExtensions (e: [ e.httpfs ]);
          duckdb-all = all;

          # Development only, for finding build errors quickly, so they skip the
          # test suite that the real packages run: stop after CMake configures,
          # or build everything and keep going past failures to see every error.
          dev-configure = all.overrideAttrs {
            outputs = [ "out" ];
            dontBuild = true;
            dontFixup = true;
            doInstallCheck = false;
            installPhase = "touch $out";
          };
          dev-keep-going = all.overrideAttrs {
            doInstallCheck = false;
            ninjaFlags = [
              "-k"
              "0"
            ];
          };
        }
        # the prepared source of each extension, to test patches without building DuckDB
        // pkgs.lib.mapAttrs' (
          name: ext: pkgs.lib.nameValuePair "source-${name}" ext.source
        ) pkgs.duckdb.extensions
      );

      checks = forAllSystems (pkgs: import ./checks.nix { inherit pkgs; });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
