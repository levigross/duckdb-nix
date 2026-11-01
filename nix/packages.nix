_:

{
  perSystem =
    {
      lib,
      pkgs,
      forEachNixpkgs,
      ...
    }:
    let
      packagesFor =
        nixpkgs:
        let
          inherit (nixpkgs) duckdb;
          all = duckdb.withExtensions (_: duckdb.linkableExtensions);

          # the same build without its test suite, for iterating
          withoutTests = all.overrideAttrs {
            doInstallCheck = false;
            ninjaFlags = [
              "-k"
              "0"
            ];
          };

          # DuckDB with one extension (and what it needs), for each this nixpkgs can link
          withOne = lib.listToAttrs (
            map (
              ext: lib.nameValuePair "duckdb-${ext.name}" (duckdb.withExtensions (e: [ e.${ext.name} ]))
            ) duckdb.linkableExtensions
          );
        in
        withOne
        // {
          default = duckdb;
          inherit duckdb;
          duckdb-all = all;

          # Development only, for finding build errors quickly, so they skip the
          # test suite that the real packages run.

          # stop after CMake configures
          dev-configure = all.overrideAttrs {
            outputs = [ "out" ];
            dontBuild = true;
            dontFixup = true;
            doInstallCheck = false;
            installPhase = "touch $out";
          };
          # build everything and keep going past failures, to see every error
          dev-keep-going = withoutTests;
          # a small set that reproduces the extension-related test failures, for
          # `nix develop` and a persistent build directory
          dev-test-shell = duckdb.withExtensions (e: [
            e.quack
            e.sqlite_scanner
          ]);
          # the checks against the build without tests
          dev-check = import ./checks/all-extensions.nix {
            pkgs = nixpkgs;
            duckdb = withoutTests;
            extensions = duckdb.linkableExtensions;
          };
          dev-rust-check = import ./checks/rust-consumer.nix {
            pkgs = nixpkgs;
            duckdb = withoutTests;
            extensions = duckdb.linkableExtensions;
          };
        };

      # The prepared source of each extension, to test patches without building
      # DuckDB, and the Rust part of those that have one, to build it on its own.
      # They do not depend on the nixpkgs, so there is one of each.
      partsOfExtensions =
        lib.mapAttrs' (name: ext: lib.nameValuePair "source-${name}" ext.src) pkgs.duckdb.extensions
        // lib.mapAttrs' (name: ext: lib.nameValuePair "rust-${name}" ext.rust.package) (
          lib.filterAttrs (_: ext: ext.rust != null) pkgs.duckdb.extensions
        );
    in
    {
      packages = forEachNixpkgs packagesFor // partsOfExtensions;
      formatter = pkgs.nixfmt;
    };
}
