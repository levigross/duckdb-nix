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
    })
  ];
}
