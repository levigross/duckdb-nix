{
  description = "DuckDB with extensions linked in, for the CLI, Python and Rust";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # the overlay and the checks must also work with the current stable release
    # and the one before it
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-previous.url = "github:NixOS/nixpkgs/nixos-25.11";

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
      nixpkgs-stable,
      nixpkgs-previous,
      crane,
      rust-overlay,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor =
        input: system:
        import input {
          inherit system;
          overlays = [ self.overlays.default ];
        };

      # The same outputs from the older nixpkgs go beside the others, behind a prefix.
      prefixed = prefix: nixpkgs.lib.mapAttrs' (name: nixpkgs.lib.nameValuePair "${prefix}${name}");
      withOlder =
        outputs: system:
        outputs (pkgsFor nixpkgs system)
        // prefixed "stable-" (outputs (pkgsFor nixpkgs-stable system))
        // prefixed "previous-" (outputs (pkgsFor nixpkgs-previous system));

      linkable =
        pkgs:
        pkgs.lib.filter (ext: ext.linkable && ext.unsupported == null) (
          pkgs.lib.attrValues pkgs.duckdb.extensions
        );

      builds =
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
          # the Rust consumer against the build without tests, for iterating
          dev-rust-check = import ./rust-consumer-check.nix {
            inherit pkgs;
            duckdb = devBuild;
            extensions = linkable pkgs;
          };
          dev-keep-going = devBuild;
          # the checks/all-extensions check, against the build without tests
          dev-check = import ./all-extensions-check.nix {
            inherit pkgs;
            duckdb = devBuild;
            extensions = linkable pkgs;
          };
        };

      # the prepared source of each extension, to test patches without building DuckDB,
      # and the Rust part of the ones that have one, to build it on its own
      parts =
        pkgs:
        pkgs.lib.mapAttrs' (
          name: ext: pkgs.lib.nameValuePair "source-${name}" ext.source
        ) pkgs.duckdb.extensions
        // pkgs.lib.mapAttrs' (name: ext: pkgs.lib.nameValuePair "rust-${name}" ext.rust.package) (
          pkgs.lib.filterAttrs (_: ext: ext.rust != null) pkgs.duckdb.extensions
        );
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

      # The extensions are the same whichever nixpkgs builds them, so their parts
      # are only listed once.
      packages = forAllSystems (system: withOlder builds system // parts (pkgsFor nixpkgs system));

      checks = forAllSystems (withOlder (pkgs: import ./checks.nix { inherit pkgs; }));

      formatter = forAllSystems (system: (pkgsFor nixpkgs system).nixfmt);
    };
}
