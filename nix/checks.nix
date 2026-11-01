_:

{
  perSystem =
    {
      pkgs,
      forEachNixpkgs,
      ...
    }:
    {
      checks = forEachNixpkgs (nixpkgs: import ./checks { pkgs = nixpkgs; }) // {
        # one build of it is enough: the mechanism is the same for every nixpkgs
        example-extension = import ./checks/example-extension.nix { inherit pkgs; };
      };
    };
}
