{
  lib,
  duckdb,
  fetchFromGitHub,
  writeText,
  stdenv,
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
      unlinkable = lib.filter (ext: !ext.linkable) selected;

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
            EXTENSION_VERSION "${builtins.substring 0 10 ext.rev}")
        '') selected
      );

      testRuns = lib.concatMap (ext: ext.testRuns) selected;

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

      # What the main pass does not run, and why. `paths` are SQL test scripts,
      # which the suite's own configuration can skip; `names` are C++ test cases,
      # which only its command line can exclude.
      testSkips = [
        {
          reason = "installs an extension over HTTP and checks the response log, which needs network access";
          paths = [ "test/sql/logging/http_response_log_redaction.test" ];
        }
      ]
      ++ lib.concatMap (ext: ext.testSkips) selected
      # not given up on: each of these runs below, apart
      ++ map (run: {
        reason = "run on its own${
          lib.optionalString (run.loads != [ ]) " with ${lib.concatStringsSep ", " run.loads} loaded"
        }: ${run.reason}";
        paths = run.tests;
      }) testRuns;

      testConfig = writeText "duckdb-test-config.json" (
        builtins.toJSON {
          description = "Settings for the packaged build";
          skip_tests = map (skip: { inherit (skip) reason paths; }) (
            lib.filter (skip: skip ? paths) testSkips
          );
        }
      );

      # the C++ test cases left out of the main pass
      testExcludes = lib.concatMapStrings (name: "exclude:${lib.escapeShellArg name} ") (
        lib.concatMap (skip: skip.names or [ ]) testSkips
      );

      # nothing is left out silently: the build log says what and why
      testNotes = lib.concatMapStrings (
        skip:
        lib.concatMapStrings (
          item: "echo ${lib.escapeShellArg "not run in the main pass: ${item}: ${skip.reason}"}\n"
        ) ((skip.paths or [ ]) ++ (skip.names or [ ]))
      ) testSkips;

      # Tests that need something different from the main pass run apart: more
      # loaded than the suite loads by itself, or a process of their own. That keeps
      # the tests that assert an extension is absent seeing it absent, and the ones
      # that disturb each other apart.
      testRunCommands = lib.concatStrings (
        lib.imap0 (
          i: run:
          let
            config = writeText "duckdb-test-config-run${toString i}.json" (
              builtins.toJSON {
                description = "${run.reason}";
                # This replaces the suite's default set rather than adding to it,
                # and core_functions is part of that default.
                statically_loaded_extensions = [ "core_functions" ] ++ run.loads;
              }
            );
          in
          ''
            HOME="$(mktemp -d)" DUCKDB_TEST_CONFIG=${config} ${libraryPathVariable}="$lib/lib" ./test/unittest ${lib.escapeShellArg (lib.concatStringsSep "," run.tests)}
          ''
        ) testRuns
      );
      libraryPathVariable =
        if stdenv.hostPlatform.isDarwin then "DYLD_LIBRARY_PATH" else "LD_LIBRARY_PATH";

      # where nixpkgs starts the suite, to give it the configuration
      testCommandPrefix = ''HOME="$(mktemp -d)" '';

      # On x86_64 nixpkgs throws the runner's standard output away, to stay under
      # Hydra's log limit. That is where it reports failures of its C++ tests, so
      # such a failure showed up as an exit code and nothing else. Keep the output
      # and print the failures if the suite fails.
      testOutputDiscard = " >/dev/null";
      testOutputKeep = ''
         > "$TMPDIR/unittest.stdout" || {
          status=$?
          echo "The test runner exited with $status. Its standard output, which nixpkgs discards, reports failures of its C++ tests:" >&2
          grep -B3 -A12 -E ': FAILED:' "$TMPDIR/unittest.stdout" | grep -v 'Replacing deprecated' | head -150 >&2
          exit $status
        }'';
    in
    lib.throwIf (unlinkable != [ ])
      "${
        lib.concatMapStringsSep ", " (ext: ext.name) unlinkable
      }: C API extensions can only be loaded at runtime, not linked in"
      (
        duckdb.overrideAttrs (
          old:
          {
            inherit (versions) version rev;

            src = duckdbSrc;

            buildInputs = old.buildInputs ++ lib.concatMap (ext: ext.buildInputs) selected;
            nativeBuildInputs = old.nativeBuildInputs ++ lib.concatMap (ext: ext.nativeBuildInputs) selected;

            cmakeFlags =
              # nixpkgs points this at in_tree_extensions.cmake, which 2.0 reorganised
              (builtins.filter (flag: !lib.hasPrefix "-DDUCKDB_EXTENSION_CONFIGS:STRING=" flag) old.cmakeFlags)
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
            installCheckPhase =
              assert lib.assertMsg (lib.hasInfix testCommandPrefix old.installCheckPhase)
                "nixpkgs' duckdb no longer starts the test suite as expected, so the test configuration cannot be passed";
              builtins.replaceStrings
                [ testCommandPrefix testOutputDiscard "./test/unittest " ]
                [
                  # what is left out, the tests that run apart (a few seconds), then the suite
                  "${testNotes}${testRunCommands}${testCommandPrefix}DUCKDB_TEST_CONFIG=${testConfig} "
                  testOutputKeep
                  "./test/unittest ${testExcludes}"
                ]
                old.installCheckPhase;

            # passthru is not part of the derivation hash
            passthru =
              # pythonHash belongs to the nixpkgs release; python3Packages.duckdb
              # must fail to evaluate until it is ported rather than use a stale one
              (removeAttrs old.passthru [ "pythonHash" ]) // {
                extensions = available;
                linkedExtensions = selected;
                # the configuration the test suite is run with
                inherit testConfig;
                withExtensions = select: mkDuckdb (select available);
              };
          }
          # Only set when there is something to add: the build without extensions
          # must not change when this machinery does, or Nix rebuilds it for nothing.
          // lib.optionalAttrs (selected != [ ]) {
            postPatch = (old.postPatch or "") + ''
              mkdir -p extension_external
              ${lib.concatMapStrings (ext: ''
                cp -R ${ext.source} extension_external/${ext.name}
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
