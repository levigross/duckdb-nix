# The overlay, which is how the rest of the world uses this: it replaces `duckdb`
# with one that has `withExtensions`.
{ inputs, ... }:

{
  flake.overlays.default = inputs.nixpkgs.lib.composeManyExtensions [
    inputs.rust-overlay.overlays.default
    (final: prev: {
      # 1.99.1 is the toolchain vortex pins; the others need less
      duckdbCraneLib = (inputs.crane.mkLib final).overrideToolchain (
        p: p.rust-bin.stable."1.99.1".minimal
      );
      duckdb = final.callPackage ../pkgs/duckdb { inherit (prev) duckdb; };
    })
  ];
}
