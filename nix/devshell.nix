# The tools that CI runs, from the same nixpkgs as everything else, so that a
# change in them cannot fail CI on its own.
_:

{
  perSystem =
    { pkgs, ... }:
    {
      devShells.default = pkgs.mkShellNoCC {
        packages = [
          pkgs.actionlint
          pkgs.deadnix
          pkgs.nixfmt
          pkgs.shellcheck
          pkgs.statix
        ];
      };
    };
}
