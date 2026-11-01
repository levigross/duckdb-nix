# DuckDB's own test suite, which runs in installCheckPhase as it does in nixpkgs,
# except for what cannot pass once extensions are linked in. Each test left out
# is listed with its reason in the build log, and the ones that need something
# different run apart instead of being dropped.
{
  lib,
  stdenv,
  writeText,
}:

# the extensions linked in
selected:

let
  testRuns = lib.concatMap (ext: ext.testRuns) selected;

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
{
  # the configuration the main pass is run with
  inherit testConfig;

  # nixpkgs' installCheckPhase, changed to leave out what testSkips lists, run
  # what testRuns lists on its own, and keep the runner's output
  installCheckPhase =
    nixpkgsPhase:
    assert lib.assertMsg (lib.hasInfix testCommandPrefix nixpkgsPhase)
      "nixpkgs' duckdb no longer starts the test suite as expected, so the test configuration cannot be passed";
    lib.replaceStrings
      [ testCommandPrefix testOutputDiscard "./test/unittest " ]
      [
        # what is left out, the tests that run apart (a few seconds), then the suite
        "${testNotes}${testRunCommands}${testCommandPrefix}DUCKDB_TEST_CONFIG=${testConfig} "
        testOutputKeep
        "./test/unittest ${testExcludes}"
      ]
      nixpkgsPhase;
}
