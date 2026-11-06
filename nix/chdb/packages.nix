_:

{
  perSystem =
    {
      lib,
      forEachNixpkgs,
      ...
    }:
    {
      # only for the systems the upstream builds libchdb for
      packages = forEachNixpkgs (
        nixpkgs:
        lib.optionalAttrs (lib.meta.availableOn nixpkgs.stdenv.hostPlatform nixpkgs.chdb) {
          inherit (nixpkgs) chdb;
          python3-chdb = nixpkgs.chdb.pythonModule nixpkgs.python3Packages;

          # Development only: the crate chdb-rust with rustls in its build script, which
          # scripts/update-chdb-rust.sh needs to lock the build of the Rust example with rustls
          dev-chdb-rust-rustls-crate =
            (import ./rust.nix {
              pkgs = nixpkgs;
              inherit (nixpkgs) chdb;
            }).crateForRustls;
        }
      );
    };
}
