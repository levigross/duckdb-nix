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

        # the package set of each nixpkgs, by the prefix of the names of its outputs
        nixpkgsSets = lib.mapAttrs (_: pkgsFrom) nixpkgsByPrefix;

        # The name of a DuckDB line in an attribute name: "1.4" is "-1_4", since a
        # dot in a name has to be quoted on the command line.
        lineTag = line: "-${lib.replaceStrings [ "." ] [ "_" ] line}";

        # The DuckDB line that each older nixpkgs ships. It is built and checked on
        # that nixpkgs, as the default version is on all of them; on the others it
        # is only evaluated.
        shippedLines = {
          "stable-" = "1.5";
          "previous-" = "1.4";
        };

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
