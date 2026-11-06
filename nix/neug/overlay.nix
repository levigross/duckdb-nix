# NeuG's part of the overlay: `neug`, which nixpkgs does not have.
final: _prev: {
  neug = final.callPackage ../../pkgs/neug { };
}
