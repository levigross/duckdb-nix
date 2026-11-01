{
  lib,
  duckdb,
  fetchFromGitHub,
  writeText,
  callPackage,
}:

let
  versions = lib.importJSON ./versions.json;

  duckdbSrc = fetchFromGitHub {
    owner = "duckdb";
    repo = "duckdb";
    tag = "v${versions.version}";
    inherit (versions) hash;
  };

  isolateRust = callPackage ./isolate-rust.nix { };

  mkExtension = import ./mk-extension.nix { inherit lib; };

  # callPackage adds override/overrideDerivation, which are not extensions
  available =
    removeAttrs
      (callPackage ./extensions {
        inherit duckdbSrc;
        duckdbVersion = "v${versions.version}";
      })
      [
        "override"
        "overrideDerivation"
      ];

  # built from DuckDB's own tree and linked by default, as in nixpkgs
  inTreeExtensions = [
    "autocomplete"
    "core_functions"
    "icu"
    "json"
    "parquet"
    "tpcds"
    "tpch"
  ];

  # The requested extensions and what they need, each after its own
  # dependencies, since that is the order DuckDB registers them in.
  addWithDependencies =
    acc: ext:
    if lib.any (seen: seen.name == ext.name) acc then
      acc
    else
      lib.foldl' addWithDependencies acc (map (name: available.${name}) ext.dependencies) ++ [ ext ];
  withDependencies = lib.foldl' addWithDependencies [ ];

  mkDuckdb =
    requested:
    let
      selected = withDependencies requested;
      tests = callPackage ./tests.nix { } selected;
      unlinkable = lib.filter (ext: !ext.linkable) selected;

      # what makes the selection impossible
      problems =
        map (ext: "${ext.name}: ${ext.unsupported}") (lib.filter (ext: ext.unsupported != null) selected)
        ++ map (
          ext: "${ext.name}: C API extensions can only be loaded at runtime, not linked in"
        ) unlinkable;

      # Out-of-tree extensions are built from sources prepared by Nix, since
      # CMake cannot reach the network in the build sandbox. They are linked
      # into DuckDB, so they need no signature and no extension directory.
      extensionConfig = writeText "duckdb-extensions.cmake" (
        lib.concatMapStrings (ext: ''
          duckdb_extension_load(${ext.name}
            SOURCE_DIR "''${PROJECT_SOURCE_DIR}/extension_external/${ext.name}"
            ${lib.optionalString (
              ext.include != null
            ) ''INCLUDE_DIR "''${PROJECT_SOURCE_DIR}/extension_external/${ext.name}/${ext.include}"''}
            EXTENSION_VERSION "${ext.version}")
        '') selected
      );

      # The Rust static libraries of the selected extensions. One keeps its copy
      # of Rust's standard library to itself; two or more would clash in the
      # link, so each is given a private one (see isolate-rust.nix).
      withRust = lib.filter (ext: ext.rust != null) selected;
      rustArchive = ext: "${ext.rust.package}/${ext.rust.archive}";
      rustArchives =
        if lib.length withRust > 1 then
          let
            isolated = isolateRust (
              lib.genAttrs (map (ext: ext.name) withRust) (name: rustArchive available.${name})
            );
          in
          lib.genAttrs (map (ext: ext.name) withRust) (name: "${isolated}/lib/${name}.a")
        else
          lib.genAttrs (map (ext: ext.name) withRust) (name: rustArchive available.${name});

    in
    lib.throwIf (problems != [ ]) "cannot build: ${lib.concatStringsSep "; " problems}" (
      duckdb.overrideAttrs (
        old:
        {
          inherit (versions) version rev;

          src = duckdbSrc;

          buildInputs = old.buildInputs ++ lib.concatMap (ext: ext.buildInputs) selected;
          nativeBuildInputs = old.nativeBuildInputs ++ lib.concatMap (ext: ext.nativeBuildInputs) selected;

          cmakeFlags =
            # nixpkgs points this at in_tree_extensions.cmake, which 2.0 reorganised
            (lib.filter (flag: !lib.hasPrefix "-DDUCKDB_EXTENSION_CONFIGS:STRING=" flag) old.cmakeFlags)
            ++ [
              # 2.0 takes the release version and commit separately
              (lib.cmakeFeature "DUCKDB_EXPLICIT_VERSION" "v${versions.version}")
              (lib.cmakeFeature "GIT_COMMIT_HASH" versions.rev)
              (lib.cmakeFeature "BUILD_EXTENSIONS" (lib.concatStringsSep ";" inTreeExtensions))
              # link the extensions as well as build them
              (lib.cmakeBool "LINK_CORE_EXTENSIONS" true)
              # Without local_extension_repository, which would point INSTALL
              # at a repository in the build directory that is gone at runtime.
              (lib.cmakeFeature "DUCKDB_CAPABILITIES" "httplib;loadable_extensions")
            ]
            ++ lib.optionals (selected != [ ]) [
              (lib.cmakeFeature "DUCKDB_EXTENSION_CONFIGS" "${extensionConfig}")
              # The order here is the order DuckDB registers them in, and an
              # extension that needs parquet or json fails to load if they
              # come later. So the in-tree ones first, then ours with their
              # dependencies ahead of them.
              (lib.cmakeFeature "STATICALLY_LINK_EXTENSIONS" (
                lib.concatStringsSep ";" (inTreeExtensions ++ map (ext: ext.name) selected)
              ))
            ]
            ++ map (ext: lib.cmakeFeature ext.rust.cmakeVariable rustArchives.${ext.name}) withRust
            ++ lib.concatMap (ext: ext.cmakeFlags) selected;

          # doInstallCheck stays as nixpkgs sets it, so DuckDB's own test suite runs.
          installCheckPhase = tests.installCheckPhase old.installCheckPhase;

          # passthru is not part of the derivation hash
          passthru =
            # pythonHash belongs to the nixpkgs release; python3Packages.duckdb
            # must fail to evaluate until it is ported rather than use a stale one
            (removeAttrs old.passthru [ "pythonHash" ]) // {
              extensions = available;
              # for linking an extension that is not one of these, see templates/extension
              inherit mkExtension;
              # all those this nixpkgs can link in, for building with every one
              linkableExtensions = lib.filter (ext: ext.linkable && ext.unsupported == null) (
                lib.attrValues available
              );
              linkedExtensions = selected;
              # the configuration the test suite is run with
              inherit (tests) testConfig;
              withExtensions = select: mkDuckdb (select available);
            };
        }
        # Only set when there is something to add: the build without extensions
        # must not change when this machinery does, or Nix rebuilds it for nothing.
        // lib.optionalAttrs (selected != [ ]) {
          postPatch = (old.postPatch or "") + ''
            mkdir -p extension_external
            ${lib.concatMapStrings (ext: ''
              cp -R ${ext.src} extension_external/${ext.name}
              chmod -R u+w extension_external/${ext.name}
            '') selected}
          '';

          # CMake only notes "requested but not built" for an extension that
          # has no static library, then carries on without it. Fail instead.
          preInstall = (old.preInstall or "") + ''
            for ext in ${lib.escapeShellArgs (map (ext: ext.name) selected)}; do
              if [ ! -e "extension/$ext/lib''${ext}_extension.a" ]; then
                echo "extension $ext was requested but not built (no static library)" >&2
                exit 1
              fi
            done
          '';
        }
      )
    );
in
mkDuckdb [ ]
