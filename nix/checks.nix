_:

{
  perSystem =
    {
      lib,
      pkgs,
      forEachNixpkgs,
      nixpkgsSets,
      shippedLines,
      lineTag,
      ...
    }:
    {
      checks =
        forEachNixpkgs (nixpkgs: import ./checks { pkgs = nixpkgs; })
        # The DuckDB that each older nixpkgs ships, on that nixpkgs. Not the check
        # with a Rust program, since the version of the `duckdb` crate that matches
        # such a DuckDB is not established.
        // lib.concatMapAttrs (
          prefix: line:
          let
            nixpkgs = nixpkgsSets.${prefix};
            checks = import ./checks {
              pkgs = nixpkgs // {
                duckdb = nixpkgs.duckdbVersions.${line};
              };
            };
          in
          lib.mapAttrs' (name: check: lib.nameValuePair "${prefix}${name}${lineTag line}" check) (
            removeAttrs checks [ "rust-consumer" ]
          )
        ) shippedLines
        // {
          # one build of it is enough: the mechanism is the same for every nixpkgs
          example-extension = import ./checks/example-extension.nix { inherit pkgs; };
        };
    };
}
