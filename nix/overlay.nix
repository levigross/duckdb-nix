# The overlay, which is how the rest of the world uses this. It is the overlays of the
# engines, one after the other; each lives with the engine, in nix/<engine>/overlay.nix.
{ inputs, ... }:

{
  flake.overlays.default = inputs.nixpkgs.lib.composeManyExtensions [
    # the official Rust toolchain, which the Rust parts of some extensions are built with
    inputs.rust-overlay.overlays.default
    (import ./duckdb/overlay.nix)
    (import ./chdb/overlay.nix)
    (import ./zvec/overlay.nix)
    (import ./neug/overlay.nix)
  ];
}
