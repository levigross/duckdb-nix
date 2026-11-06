# chDB's part of the overlay: `chdb`, which nixpkgs does not have.
final: _prev: {
  chdb = final.callPackage ../../pkgs/chdb { };
}
