# NeuG's part of the overlay: `neug`, which nixpkgs does not have, and `neug-c`, the C
# interface that its Rust crates are made on.
final: _prev: {
  neug = final.callPackage ../../pkgs/neug { };
  neug-c = final.callPackage ../../pkgs/neug-c { };
}
