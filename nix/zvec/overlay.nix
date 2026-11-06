# zvec's part of the overlay: `zvec`, which nixpkgs does not have.
final: _prev: {
  zvec = final.callPackage ../../pkgs/zvec { };
}
