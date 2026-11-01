# Each extension is pinned to the commit its source names: DuckDB's configuration
# for the release or, for a community extension, its descriptor in
# duckdb/community-extensions. Each is read with something that understands its
# format, and the result is compared with what is packaged, so a pin that is
# wrong, missing or extra shows up as a diff.
{ pkgs }:

let
  inherit (pkgs) lib duckdb;

  packaged = lib.mapAttrs (_: ext: {
    url = "https://github.com/${ext.owner}/${ext.repo}";
    inherit (ext) rev;
  }) duckdb.extensions;

  descriptor =
    ext:
    pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/duckdb/community-extensions/${ext.community.rev}/extensions/${ext.name}/description.yml";
      hash = ext.community.descriptorHash;
    };
in
pkgs.runCommand "duckdb-extension-pins"
  {
    nativeBuildInputs = [
      pkgs.cmake
      pkgs.jq
      pkgs.yq-go
    ];
  }
  ''
    for config in ${duckdb.src}/.github/config/extensions/*.cmake; do
      cmake -DCONFIG="$config" -DOUT=declared.jsonl -P ${./extension-config.cmake}
    done

    ${lib.concatMapStrings (ext: ''
      yq -o=json ${descriptor ext} |
        jq -c --arg name ${ext.name} '{($name): {url: "https://github.com/\(.repo.github)", rev: .repo.ref}}' >> declared.jsonl
    '') (lib.filter (ext: ext.community != null) (lib.attrValues duckdb.extensions))}

    # test_utils is DuckDB's own backwards compatibility test, not an extension to ship
    jq -S -s 'add | del(.test_utils)' declared.jsonl > declared.json
    jq -S . ${pkgs.writeText "packaged-pins.json" (builtins.toJSON packaged)} > packaged.json

    diff --unified --label "declared by the sources" --label packaged declared.json packaged.json
    touch $out
  ''
