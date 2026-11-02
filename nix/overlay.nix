# The overlay, which is how the rest of the world uses this: it replaces `duckdb`
# with one that has `withExtensions`.
{ inputs, ... }:

{
  flake.overlays.default = inputs.nixpkgs.lib.composeManyExtensions [
    inputs.rust-overlay.overlays.default
    (final: prev: {
      # The Rust parts of some extensions build with the official toolchain, which
      # bundles the LLVM its standard library expects. nixpkgs' rustc 1.99 is
      # linked against LLVM 21, and its AVX-512 VNNI intrinsics do not match.
      # 1.99.1 is the toolchain vortex pins; the others need less.
      duckdbRustPlatform =
        let
          toolchain = final.rust-bin.stable."1.99.1".minimal;
        in
        final.makeRustPlatform {
          cargo = toolchain;
          rustc = toolchain;
        };
      duckdb = final.callPackage ../pkgs/duckdb { inherit (prev) duckdb; };

      # Every DuckDB version that is pinned, by release ("1.4.3") and by line ("1.4").
      # `duckdb` is the default one.
      duckdbVersions =
        let
          releases = final.lib.attrNames (
            final.lib.filterAttrs (_: type: type == "directory") (builtins.readDir ../pkgs/duckdb/versions)
          );
          byRelease = final.lib.genAttrs releases (
            release:
            final.callPackage ../pkgs/duckdb {
              inherit (prev) duckdb;
              inherit release;
            }
          );
        in
        byRelease
        // final.lib.mapAttrs' (
          release: duckdb: final.lib.nameValuePair (final.lib.versions.majorMinor release) duckdb
        ) byRelease;
    })
  ];
}
