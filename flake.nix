{
  description = "DuckDB with extensions linked in, for the CLI, Python and Rust";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The Rust parts of some extensions build with the official toolchain, which
    # bundles the LLVM its standard library expects. nixpkgs' rustc 1.99 is
    # linked against LLVM 21, and its AVX-512 VNNI intrinsics do not match.
    crane.url = "github:ipetkov/crane";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      crane,
      rust-overlay,
    }:
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
      overlays.default = nixpkgs.lib.composeManyExtensions [
        rust-overlay.overlays.default
        (final: prev: {
          # 1.99.1 is the toolchain vortex pins; the others need less
          duckdbCraneLib = (crane.mkLib final).overrideToolchain (p: p.rust-bin.stable."1.99.1".minimal);
          duckdb = final.callPackage ./pkgs/duckdb { duckdb = prev.duckdb; };
        })
      ];

      packages = forAllSystems (
        pkgs:
        let
          all = pkgs.duckdb.withExtensions (_: linkable pkgs);
          # the same build without its test suite, for iterating
          devBuild = all.overrideAttrs {
            doInstallCheck = false;
            ninjaFlags = [
              "-k"
              "0"
            ];
          };
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
          # a small set that reproduces the extension-related test failures, for
          # `nix develop` and a persistent build directory
          dev-test-shell = pkgs.duckdb.withExtensions (e: [
            e.quack
            e.sqlite_scanner
          ]);
          dev-keep-going = devBuild;
          # the checks/all-extensions check, against the build without tests
          dev-check = import ./all-extensions-check.nix {
            inherit pkgs;
            duckdb = devBuild;
            extensions = linkable pkgs;
          };
        }
        # the prepared source of each extension, to test patches without building DuckDB
        // pkgs.lib.mapAttrs' (
          name: ext: pkgs.lib.nameValuePair "source-${name}" ext.source
        ) pkgs.duckdb.extensions
        # the Rust part of the extensions that have one, to build it on its own
        // pkgs.lib.mapAttrs' (name: ext: pkgs.lib.nameValuePair "rust-${name}" ext.rust.package) (
          pkgs.lib.filterAttrs (_: ext: ext.rust != null) pkgs.duckdb.extensions
        )
      );

      checks = forAllSystems (pkgs: import ./checks.nix { inherit pkgs; });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
