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
        }
      );
    };
}
