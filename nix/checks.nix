_:

{
  perSystem =
    {
      lib,
      pkgs,
      forEachNixpkgs,
      nixpkgsSets,
      lineTag,
      ...
    }:
    {
      checks =
        forEachNixpkgs (nixpkgs: import ./checks { pkgs = nixpkgs; })
        # Every other pinned line of DuckDB, on every nixpkgs
        // lib.concatMapAttrs (
          prefix: nixpkgs:
          lib.concatMapAttrs
            (
              line: duckdb:
              lib.mapAttrs' (name: check: lib.nameValuePair "${prefix}${name}${lineTag line}" check) (
                import ./checks {
                  pkgs = nixpkgs // {
                    inherit duckdb;
                  };
                }
              )
            )
            (
              lib.filterAttrs (
                line: duckdb:
                builtins.match "[0-9]+\\.[0-9]+" line != null && duckdb.version != nixpkgs.duckdb.version
              ) nixpkgs.duckdbVersions
            )
        ) nixpkgsSets
        // {
          # one build of it is enough: the mechanism is the same for every nixpkgs
          example-extension = import ./checks/example-extension.nix { inherit pkgs; };
        };
    };
}
