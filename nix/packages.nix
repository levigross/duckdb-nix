_:

{
  perSystem =
    {
      lib,
      pkgs,
      forEachNixpkgs,
      lineTag,
      ...
    }:
    let

      # the same build without its test suite, for iterating
      withoutTests =
        all:
        all.overrideAttrs {
          doInstallCheck = false;
          ninjaFlags = [
            "-k"
            "0"
          ];
        };

      # DuckDB of one version: by itself, with every extension this nixpkgs can
      # link, and with each of them alone. `tag` is "" for the default version.
      packagesOfVersion =
        tag: pythonPackages: duckdb:
        let
          all = duckdb.withExtensions (_: duckdb.linkableExtensions);
        in
        lib.listToAttrs (
          map (
            ext: lib.nameValuePair "duckdb${tag}-${ext.name}" (duckdb.withExtensions (e: [ e.${ext.name} ]))
          ) duckdb.linkableExtensions
        )
        // lib.mapAttrs' (
          name: loadable: lib.nameValuePair "duckdb${tag}-${name}-loadable" loadable
        ) duckdb.loadableExtensions
        // {
          "duckdb${tag}" = duckdb;
          "duckdb${tag}-all" = all;

          # the Python module, built with the same DuckDB: plain, and with every extension
          "python3-duckdb${tag}" = duckdb.pythonModule pythonPackages;
          "python3-duckdb${tag}-all" = all.pythonModule pythonPackages;

          # Development only: stop after CMake configures
          # build everything and keep going past failures, to see every error
          "dev-keep-going${tag}" = withoutTests all;

          "dev-configure${tag}" = all.overrideAttrs {
            outputs = [ "out" ];
            dontBuild = true;
            dontFixup = true;
            doInstallCheck = false;
            installPhase = "touch $out";
          };
        };

      packagesFor =
        nixpkgs:
        let
          inherit (nixpkgs) duckdb;
          all = duckdb.withExtensions (_: duckdb.linkableExtensions);

          # the other lines of DuckDB, which are pinned as well as the default one
          otherLines = lib.filterAttrs (
            line: other: builtins.match "[0-9]+\\.[0-9]+" line != null && other.version != duckdb.version
          ) nixpkgs.duckdbVersions;
        in
        packagesOfVersion "" nixpkgs.python3Packages duckdb
        // lib.concatMapAttrs (
          line: other: packagesOfVersion (lineTag line) nixpkgs.python3Packages other
        ) otherLines
        // {
          default = duckdb;

          # Development only, for finding build errors quickly, so they skip the
          # test suite that the real packages run.

          # a small set that reproduces the extension-related test failures, for
          # `nix develop` and a persistent build directory
          dev-test-shell = duckdb.withExtensions (e: [
            e.quack
            e.sqlite_scanner
          ]);
          # the checks against the build without tests
          dev-check = import ./checks/all-extensions.nix {
            pkgs = nixpkgs;
            duckdb = withoutTests all;
            extensions = duckdb.linkableExtensions;
          };
          dev-rust-check = import ./checks/rust-consumer.nix {
            pkgs = nixpkgs;
            duckdb = withoutTests all;
            extensions = duckdb.linkableExtensions;
          };
        };

      # The prepared source of each extension, to test patches without building
      # DuckDB, and the Rust part of those that have one, to build it on its own.
      # They do not depend on the nixpkgs, so there is one of each for every
      # version of DuckDB: `source-avro` for the default, `source-1_4-avro` for 1.4.
      partsOfExtensions =
        tag: duckdb:
        let
          pinned = lib.filterAttrs (_: ext: ext.rev != null) duckdb.extensions;
        in
        lib.mapAttrs' (name: ext: lib.nameValuePair "source${tag}-${name}" ext.src) pinned
        // lib.mapAttrs' (name: ext: lib.nameValuePair "rust${tag}-${name}" ext.rust.package) (
          lib.filterAttrs (_: ext: ext.rust != null) pinned
        );
      partsOfOtherLines = lib.concatMapAttrs (
        line: other:
        lib.optionalAttrs (
          builtins.match "[0-9]+\\.[0-9]+" line != null && other.version != pkgs.duckdb.version
        ) (partsOfExtensions (lineTag line) other)
      ) pkgs.duckdbVersions;
    in
    {
      packages = forEachNixpkgs packagesFor // partsOfExtensions "" pkgs.duckdb // partsOfOtherLines;
      formatter = pkgs.nixfmt;
    };
}
