#!/usr/bin/env bash
# Which extensions each DuckDB version can have on each nixpkgs, and why not where it
# cannot: one line per extension that is not available, as
#
#   DuckDB 1.4.3  25.11   spatial   its sources need ...
#
# An extension a version does not list is linked into `withExtensions` and in the
# `-all` package. The reason is the one the flake gives when it is asked for.
#
#   scripts/availability.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC2016 # the ${} are Nix's
AVAILABILITY_ROOT="$root" nix eval --raw --impure --expr '
  let
    flake = builtins.getFlake "path:${builtins.getEnv "AVAILABILITY_ROOT"}";
    nixpkgsNames = {
      unstable = "nixpkgs";
      "26.05" = "nixpkgs-stable";
      "25.11" = "nixpkgs-previous";
    };
    lib = flake.inputs.nixpkgs.lib;
    unsupported =
      pkgs:
      lib.concatMap (
        release:
        let
          duckdb = (flake.lib.duckdbVersions pkgs).${release};
        in
        lib.concatMap (
          name:
          let
            ext = duckdb.extensions.${name};
            reason =
              if ext.unsupported != null then
                ext.unsupported
              else if !ext.linkable then
                "a C API extension, which can only be loaded at runtime, not linked in"
              else
                null;
          in
          lib.optional (reason != null) "DuckDB ${release}  ${name}  ${reason}"
        ) (lib.attrNames duckdb.extensions)
      ) [ "1.4.3" "1.5.2" "2.0.0" ];
  in
  lib.concatStringsSep "\n" (
    lib.concatMap (
      label:
      map (line: "${label}  ${line}") (unsupported flake.inputs.${nixpkgsNames.${label}}.legacyPackages.${builtins.currentSystem})
    ) (lib.attrNames nixpkgsNames)
  )
' | sed 's/^\([^ ]*\)  \(DuckDB [^ ]*\)  /\2  \1  /' | sort -V
