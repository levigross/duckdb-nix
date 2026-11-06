_:

{
  perSystem =
    {
      lib,
      forEachNixpkgs,
      ...
    }:
    {
      checks = forEachNixpkgs (
        nixpkgs:
        lib.optionalAttrs (lib.meta.availableOn nixpkgs.stdenv.hostPlatform nixpkgs.chdb) (
          lib.mapAttrs' (name: check: lib.nameValuePair "chdb-${name}" check) (
            import ./checks { pkgs = nixpkgs; }
          )
        )
      );
    };
}
