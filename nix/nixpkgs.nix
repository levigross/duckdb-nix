# The nixpkgs the outputs are built with. The overlay has to work with the
# current stable release and the one before it as well as with unstable, so
# every package and check exists for each: unstable under its own name, the
# others behind a prefix.
{
  inputs,
  lib,
  self,
  ...
}:

let
  nixpkgsByPrefix = {
    "" = inputs.nixpkgs;
    "stable-" = inputs.nixpkgs-stable;
    "previous-" = inputs.nixpkgs-previous;
  };
in
{
  perSystem =
    { system, ... }:
    let
      pkgsFrom =
        nixpkgs:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };
    in
    {
      _module.args = {
        pkgs = pkgsFrom inputs.nixpkgs;

        # `outputsFor` takes a package set and returns an attribute set. This
        # gives the union of what it returns for each nixpkgs.
        forEachNixpkgs =
          outputsFor:
          lib.concatMapAttrs (
            prefix: nixpkgs:
            lib.mapAttrs' (name: lib.nameValuePair "${prefix}${name}") (outputsFor (pkgsFrom nixpkgs))
          ) nixpkgsByPrefix;
      };
    };
}
