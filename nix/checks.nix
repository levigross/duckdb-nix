{ ... }:

{
  perSystem =
    { forEachNixpkgs, ... }:
    {
      checks = forEachNixpkgs (pkgs: import ./checks { inherit pkgs; });
    };
}
