# Extensions that cannot be linked into DuckDB, because their repository builds against
# a fork of it, so they are loaded instead. Each is offered twice, as the registry offers
# it:
#
#   <name>            built here from the sources, as the registry builds it: the fork,
#                     with the extension loaded in. DuckDB loads it only when unsigned
#                     extensions are allowed (`duckdb -unsigned`, or allow_unsigned_extensions)
#   <name>-registry   the registry's own build for the release, as a file pinned by its
#                     hash, which carries the registry's signature. It is not built here
#
# They are loaded with LOAD, from the path or from the directory:
#
#   LOAD '${pkg}/lib/duckpgq.duckdb_extension';
#   SET extension_directory = '${pkg}/share/duckdb/extensions'; LOAD duckpgq;
{
  lib,
  stdenv,
  runCommand,
  fetchurl,
  fetchFromGitHub,
  cmake,
  ninja,
  python3,
  openssl,
  duckdbVersion,
  # name to { platforms.<system> = { url, hash }; source.{extension,duckdb} = pin }
  entries,
}:

let
  system = stdenv.hostPlatform.system;

  # The platform directory DuckDB uses for the system
  platformOf =
    {
      x86_64-linux = "linux_amd64";
      aarch64-linux = "linux_arm64";
      x86_64-darwin = "osx_amd64";
      aarch64-darwin = "osx_arm64";
    }
    .${system};

  # What must work with the extension loaded. The statements are separate commands,
  # since duckpgq reads the tables as it parses the statement that creates a graph.
  smokes = {
    duckpgq = [
      "CREATE TABLE person AS SELECT * FROM (VALUES (1), (2), (3)) t(id); CREATE TABLE knows AS SELECT * FROM (VALUES (1, 2), (2, 3)) t(a, b)"
      "CREATE PROPERTY GRAPH g VERTEX TABLES (person) EDGE TABLES (knows SOURCE KEY (a) REFERENCES person (id) DESTINATION KEY (b) REFERENCES person (id) LABEL knows)"
      "SELECT CASE WHEN count(*) = 2 THEN 1 ELSE error('graph match') END FROM GRAPH_TABLE (g MATCH (x:person)-[k:knows]->(y:person) COLUMNS (x.id AS a, y.id AS b))"
      "SELECT CASE WHEN max(hops) = 2 THEN 1 ELSE error('shortest path') END FROM GRAPH_TABLE (g MATCH p = ANY SHORTEST (x:person)-[k:knows]->{1,3}(y:person) COLUMNS (x.id AS a, y.id AS b, path_length(p) AS hops))"
    ];
  };

  # what the check runs: the file to load, the SQL that proves it works, and whether
  # DuckDB has to be told to load it
  passthruOf = name: unsigned: {
    inherit name unsigned;
    path = "lib/${name}.duckdb_extension";
    smoke = smokes.${name} or [ ];
  };

  layout = name: ''
    mkdir -p $out/share/duckdb/extensions/${duckdbVersion}/${platformOf}
    ln -s $out/lib/${name}.duckdb_extension $out/share/duckdb/extensions/${duckdbVersion}/${platformOf}/${name}.duckdb_extension
  '';

  fromRegistry =
    name: entry:
    let
      file = entry.platforms.${system} or (throw "the registry published no ${name} for ${system}");
      src = fetchurl { inherit (file) url hash; };
    in
    runCommand "duckdb-${name}-${duckdbVersion}-registry"
      {
        passthru = passthruOf name false;
        meta = {
          description = "The community registry's build of the ${name} extension for DuckDB ${duckdbVersion}";
          homepage = "https://duckdb.org/community_extensions/extensions/${name}";
          sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
          platforms = lib.attrNames entry.platforms;
        };
      }
      ''
        mkdir -p $out/lib
        gzip -dc ${src} > $out/lib/${name}.duckdb_extension
        ${layout name}
      '';

  # The extension loaded into the DuckDB it names as its own, built as a loadable file.
  fromSource =
    name: entry:
    let
      inherit (entry) source;
      fetch =
        pin:
        fetchFromGitHub {
          inherit (pin)
            owner
            repo
            rev
            hash
            ;
        };
    in
    stdenv.mkDerivation {
      pname = "duckdb-${name}-loadable";
      version = lib.removePrefix "v" duckdbVersion;

      dontUnpack = true;
      nativeBuildInputs = [
        cmake
        ninja
        python3
      ];
      buildInputs = [ openssl ];
      dontUseCmakeConfigure = true;

      configurePhase = ''
        runHook preConfigure
        cp -r ${fetch source.duckdb} duckdb
        cp -r ${fetch source.extension} extension
        chmod -R u+w duckdb extension
        cmake -G Ninja -S duckdb -B build \
          -DCMAKE_BUILD_TYPE=Release \
          -DEXTENSION_STATIC_BUILD=1 \
          -DDUCKDB_EXTENSION_CONFIGS=$PWD/extension/extension_config.cmake \
          -DBUILD_UNITTESTS=0 -DBUILD_SHELL=0 \
          -DOVERRIDE_GIT_DESCRIBE=${duckdbVersion}-0-g${lib.substring 0 7 source.duckdb.rev} \
          -DENABLE_EXTENSION_AUTOLOADING=1 -DENABLE_EXTENSION_AUTOINSTALL=0
        runHook postConfigure
      '';

      buildPhase = ''
        runHook preBuild
        cmake --build build --target ${name}_loadable_extension -- -j$NIX_BUILD_CORES
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out/lib
        cp "$(find build -name '${name}.duckdb_extension')" $out/lib/
        ${layout name}
        runHook postInstall
      '';

      # DuckDB appends its metadata to the file: stripping or patching it would cut that off
      dontFixup = true;

      passthru = passthruOf name true;

      meta = {
        description = "The ${name} extension for DuckDB ${duckdbVersion}, built from source as a loadable extension";
        platforms = lib.platforms.unix;
      };
    };
in
lib.concatMapAttrs (
  name: entry:
  {
    "${name}-registry" = fromRegistry name entry;
  }
  // lib.optionalAttrs (entry ? source) { ${name} = fromSource name entry; }
) entries
