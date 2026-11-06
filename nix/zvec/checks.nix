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
        lib.optionalAttrs (lib.meta.availableOn nixpkgs.stdenv.hostPlatform nixpkgs.zvec) (
          lib.mapAttrs' (name: check: lib.nameValuePair "zvec-${name}" check) (
            import ./checks { pkgs = nixpkgs; }
          )
        )
      );
    };
}
