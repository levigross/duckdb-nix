# The test suite of the crate chdb-rust, upstream's own, run against our libchdb: the crate of
# crates.io at the version the Rust example uses, with the lock file it ships (scripts/update-chdb.sh
# keeps a copy, since a build reads it at evaluation time, and the build fails if the crate's differs).
#
# Two passes, since the crate has features that change what is compiled: the default (arrow), and
# `--features durable`. A third, `durable-s3`, is not run: its one test file needs a bucket
# (CHDB_DURABLE_S3_BUCKET) and skips itself without, and what it asks of S3 is checked by
# rust-consumer-s3 against a stand-in store with a certificate of its own.
#
# One test target of the crate fails with this engine, and it says so itself (runtime_faces.rs:
# "up to chdb-core v26.11.0-rc.1 [...] chdb_shutdown refused with 'global thread pool did not
# become idle'"; the engine here is older than that). The check does not leave it out: it requires
# this case, and only this case, to fail with that message, so that an engine that fixes it makes
# the check fail until the exception is removed.
{
  pkgs,
  chdb,
  pin,
}:

let
  inherit (pkgs) lib;
  crate = pin.tests.rustCrate;

  tarball = pkgs.fetchurl {
    name = "chdb-rust-${crate.version}.tar.gz";
    inherit (crate) url hash;
  };
  src = pkgs.runCommand "chdb-rust-${crate.version}-source" { } ''
    mkdir $out
    tar -xzf ${tarball} --strip-components=1 -C $out
  '';

  # The test targets of the crate, as its manifest lists them. The check compares them with the
  # manifest it is given, so a target that upstream adds is not run unnoticed.
  targets = [
    "arrow_insert"
    "arrow_insert_bench"
    "arrow_query"
    "arrow_stream"
    "arrow_stream_roundtrip"
    "bundled_runtime_hidden"
    "durable_conformance"
    "durable_engine"
    "durable_s3"
    "engine_registry"
    "examples"
    "insert_stream"
    "params"
    "query_result"
    "query_text"
    "query_with_params"
    "result_metrics"
    "runtime_faces"
    "version"
  ];

  # What each pass must come to, for this version of the crate: the tests that passed, summed
  # over the unit tests, the test binaries and the doctests. None may fail, and those ignored
  # are the ones that upstream marks #[ignore] (four manual benchmarks, "run with --release
  # --ignored"). The sixteen cases of runtime_faces, which are processes of their own, are not
  # among them: fifteen pass, and the one that fails is below.
  passed = {
    default = 244;
    durable = 349;
  };
  runtimeCases = 16;
  # the case of runtime_faces that fails against this engine, and how
  brokenCase = "shutdown_after_mergetree_merges";
  brokenPanic = ''shutdown after MergeTree merges: EngineCallFailed { call: "chdb_shutdown" }'';
in
pkgs.rustPlatform.buildRustPackage {
  pname = "chdb-rust-tests";
  inherit (crate) version;
  inherit src;
  cargoLock.lockFile = ../../../../pkgs/chdb/chdb-rust.Cargo.lock;

  auditable = false;
  strictDeps = true;
  nativeBuildInputs = [
    pkgs.rustPlatform.bindgenHook
    pkgs.pkg-config
    pkgs.jq
  ];
  # the build script of the crate has reqwest, which wants OpenSSL
  buildInputs = [ pkgs.openssl ];

  env = {
    CHDB_LIB_DIR = "${chdb}/lib";
    CHDB_INCLUDE_DIR = "${chdb}/include";
    # test binaries without debug information link faster and are a tenth of the size
    CARGO_PROFILE_DEV_DEBUG = "0";
  };

  dontBuild = true;
  doCheck = true;

  checkPhase = ''
    runHook preCheck
    export HOME=$TMPDIR
    mkdir -p $TMPDIR/logs

    flags=(--offline -j "$NIX_BUILD_CORES" --target ${pkgs.stdenv.hostPlatform.rust.rustcTargetSpec})

    # the test targets of the crate must be the ones this check knows
    found="$(cargo metadata --offline --no-deps --format-version 1 \
      | jq -r '.packages[] | select(.name == "chdb-rust") | .targets[] | select(.kind == ["test"]) | .name' | sort | tr '\n' ' ')"
    known="${lib.concatStringsSep " " (lib.sort (a: b: a < b) targets)} "
    [ "$found" = "$known" ] || {
      echo "the manifest lists the test targets: $found" >&2
      echo "this check was written for:           $known" >&2
      exit 1
    }

    # sum of "test result: ok. 12 passed; 0 failed; 1 ignored; ..." over a log
    total() {
      awk -v what="$2" '/^test result: / { for (i = 2; i <= NF; i++) if ($i == what ";") n += $(i - 1) } END { print n + 0 }' "$1"
    }

    # one pass: the unit tests, every test binary of the crate and its doctests, one test at a time
    # since the engine is one per process and the tests of the crate say that they contend for it
    pass() {
      local name=$1; shift
      cargo test "''${flags[@]}" --no-fail-fast --lib --tests "$@" -- --test-threads=1 2>&1 | tee $TMPDIR/logs/$name.log || true
      cargo test "''${flags[@]}" --no-fail-fast --doc "$@" -- --test-threads=1 2>&1 | tee -a $TMPDIR/logs/$name.log
    }
    pass default
    pass durable --features durable

    expect() {
      [ "$2" = "$3" ] || { echo "$1: $2, and this check expects $3" >&2; failed=1; }
    }
    failed=0
    declare -A passed=([default]=${toString passed.default} [durable]=${toString passed.durable})
    ignores="$(grep -rE '#\[ignore' tests src | wc -l)"
    for name in default durable; do
      log=$TMPDIR/logs/$name.log
      echo "pass $name: $(total $log passed) passed, $(total $log failed) failed, $(total $log ignored) ignored;" \
        "runtime cases: $(grep -cE '^  [a-z_]+ \.\.\. ok' $log) ok, $(grep -cE '^  [a-z_]+ \.\.\. FAILED' $log) failed"
      expect "$name: tests that failed" "$(total $log failed)" 0
      expect "$name: tests that passed" "$(total $log passed)" ''${passed[$name]}
      expect "$name: tests ignored (the #[ignore] of upstream)" "$(total $log ignored)" "$ignores"

      # runtime_faces: the case that is broken with this engine fails the way it should, and
      # nothing else does (cargo names each target that failed)
      expect "$name: runtime cases" "$(grep -cE '^  [a-z_]+ \.\.\. (ok|FAILED)' $log)" ${toString runtimeCases}
      expect "$name: cases that failed" "$(grep -E '^  [a-z_]+ \.\.\. FAILED' $log | sed -E 's/^  ([a-z_]+) .*/\1/')" ${brokenCase}
      expect "$name: targets that failed" "$(grep -o 'error: test failed, to rerun pass .*' $log)" 'error: test failed, to rerun pass `--test runtime_faces`'
      grep -qF 'stdout was: "rows=200000|closed|"' $log || { echo "$name: the broken case did not stop at the shutdown" >&2; failed=1; }
      grep -qF '${brokenPanic}' $log || { echo "$name: the broken case did not fail with: ${brokenPanic}" >&2; failed=1; }
    done
    [ $failed = 0 ] || exit 1

    # Something must be able to fail: with an answer that the engine does not give, expected by one
    # of the tests, the same suite must fail, and at that test
    substituteInPlace tests/examples.rs --replace-fail '{\"COUNT()\":1}' '{\"COUNT()\":2}'
    status=0
    cargo test "''${flags[@]}" --test examples -- --test-threads=1 > $TMPDIR/logs/control.log 2>&1 || status=$?
    tail -n 12 $TMPDIR/logs/control.log
    [ $status != 0 ] || { echo "a test that expects what the engine does not answer passed" >&2; exit 1; }
    grep -q 'test test_stateful ... FAILED' $TMPDIR/logs/control.log

    runHook postCheck
  '';

  installPhase = ''
    mkdir -p $out
    cp $TMPDIR/logs/* $out/
  '';

  meta = {
    description = "The tests of chdb-rust ${crate.version}, run against libchdb ${chdb.version}";
    platforms = lib.platforms.linux;
  };
}
