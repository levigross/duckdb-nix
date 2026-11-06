# NeuG: its packages. The package itself is pkgs/neug.
_:

{
  imports = [
    ./packages.nix
    ./checks.nix
    ./rust-checks.nix
  ];
}
