# The tests of the Python module that chdb-core has in tests/, upstream's own, run with its
# runner (tests/run_all.py: the modules in four shards, and the ones that open a path of data
# or load the library themselves, each in a process of its own).
#
# They are the tests of the wheel of chdb-core, so the wheel is what they get, alone: the
# package python3-chdb has the wheel of chdb over it, which replaces chdb/__init__.py. The
# library that the tests of the C interface load by ctypes is the package's (CHDB_LIB_PATH).
#
# The tests that need a service skip themselves when it is not configured (a remote ClickHouse, a
# MinIO, MySQL and MongoDB, an AI provider). The runner does not count a module that skips at
# import, so the check lists those itself.
#
# Eight tests fail here, all for the same reason, and the check requires exactly those to fail:
# the sandbox has no cgroup files, and the engine then writes "Cannot use cgroups reader: ...
# Cannot find cgroups v1 or v2 current memory file" and a stack trace to stderr when it starts,
# which the tests of the noise on stdout and stderr (test_stdout_noise.py, and one of
# test_wasm_udf.py) take for noise. Where the memory files of cgroups can be read they pass.
# Three modules are left out because they read from the Internet, one when it is imported.
{
  pkgs,
  chdb,
  pin,
  modules,
}:

let
  inherit (pkgs.stdenv.hostPlatform) system;

  core = pkgs.fetchgit {
    url = "https://github.com/${pin.repo}";
    rev = pin.tag;
    sparseCheckout = pin.tests.core.sparseCheckout;
    inherit (pin.tests.core) hash;
  };

  coreWheel = pkgs.fetchurl { inherit (pin.systems.${system}.coreWheel) url hash; };

  # what the tests import: pandas, pyarrow and numpy are what the wheel needs; the others (the
  # `modules`) are for the tests of the ADBC driver, of Delta Lake, and of the federation with
  # MySQL and MongoDB
  python = pkgs.python3.withPackages (
    ps:
    [
      ps.pandas
      ps.pyarrow
      ps.numpy
    ]
    ++ map (m: ps.${m}) modules
  );

  # the tests that fail in the sandbox, as the runner names them, in the order of sort
  expectedFailing = pkgs.writeText "chdb-core-python-expected-failing" ''
    FAIL: test_aggregate_over_million_rows_no_elapsed_print (test_stdout_noise.TestStdoutNoise.test_aggregate_over_million_rows_no_elapsed_print)
    FAIL: test_create_function_without_flag_is_disabled (test_wasm_udf.TestWasmUDFDisabled.test_create_function_without_flag_is_disabled)
    FAIL: test_create_then_select_no_progress_noise (test_stdout_noise.TestStdoutNoise.test_create_then_select_no_progress_noise)
    FAIL: test_error_query_does_not_dump_exception_to_streams (test_stdout_noise.TestStdoutNoise.test_error_query_does_not_dump_exception_to_streams)
    FAIL: test_file_implicit_table_query_no_noise (test_stdout_noise.TestStdoutNoise.test_file_implicit_table_query_no_noise)
    FAIL: test_numbers_select_emits_only_rows (test_stdout_noise.TestStdoutNoise.test_numbers_select_emits_only_rows)
    FAIL: test_session_query_emits_only_result (test_stdout_noise.TestStdoutNoise.test_session_query_emits_only_result)
    FAIL: test_simple_select_emits_only_result (test_stdout_noise.TestStdoutNoise.test_simple_select_emits_only_result)
  '';
in
pkgs.runCommand "chdb-core-python-tests"
  {
    nativeBuildInputs = [
      pkgs.unzip
      # the tests ask ldd whether the system is musl
      pkgs.glibc.bin
    ];
  }
  ''
    export HOME=$TMPDIR
    # the sandbox has no store of certificate authorities and no time zone database
    export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    export TZDIR=${pkgs.tzdata}/share/zoneinfo
    mkdir -p $out
    W=$TMPDIR/chdb-core

    cp -r --no-preserve=mode ${core} $W
    ln -s ${chdb}/lib/libchdb.so $W/libchdb.so
    export CHDB_LIB_PATH=${chdb}/lib/libchdb.so
    mkdir $W/site
    unzip -q ${coreWheel} -d $W/site
    export PYTHONPATH=$W/site

    cd $W/tests

    # Left out, for they read from the Internet and cannot pass in a sandbox without a network:
    # test_delta_lake.py (a public bucket on S3: "Error performing GET https://s3..amazonaws.com/..."),
    # test_issue60.py (a Parquet file in another: an empty result) and test_on_df.py, which
    # downloads hits_0.parquet from datasets.clickhouse.com when it is imported (so the runner
    # stops loading it: "Temporary failure in name resolution").
    rm test_delta_lake.py test_issue60.py test_on_df.py

    # the modules that skip when they are imported, which the runner leaves out of its count
    for t in test_*.py; do
      ${python}/bin/python - ''${t%.py} <<'EOF' 2>/dev/null || true
    import importlib, sys, unittest
    name = sys.argv[1]
    sys.argv = sys.argv[:1]
    try:
        importlib.import_module(name)
    except unittest.SkipTest as e:
        print("skipped at import:", name, "-", e)
    except BaseException as e:
        print("cannot import:", name, "-", type(e).__name__, e)
    EOF
    done 2>&1 | tee $out/skipped-modules.log

    status=0
    timeout 3300 ${python}/bin/python run_all.py 2>&1 | tee $out/run_all.log || status=$?
    echo "$status" > $out/run_all.log.status
    echo "run_all.py: exit status $status"

    # the sums over the shards and the isolated runs, from "Ran 231 tests in 91s" and
    # "FAILED (failures=1, skipped=16)", one "word number" to a line
    awk '
      /^Ran [0-9]+ tests? in/ { n["ran"] += $2 }
      /^(OK|FAILED)/ {
        s = $0
        while (match(s, /[a-z]+( [a-z]+)?=[0-9]+/)) {
          split(substr(s, RSTART, RLENGTH), kv, "=")
          n[kv[1]] += kv[2]
          s = substr(s, RSTART + RLENGTH)
        }
      }
      END { for (k in n) print k, n[k] }
    ' $out/run_all.log | sort | tee $out/summary
    get() { awk -v k="$1" '$1 == k { print $2; found = 1 } END { if (!found) print 0 }' $out/summary; }
    # not at the start of a line: the stderr of the engine and the output of unittest interleave
    # (-a: the log has bytes that make grep take it for a binary file and print nothing of a match)
    grep -aoE '(FAIL|ERROR): test_[A-Za-z0-9_]+ \([A-Za-z0-9_.]+\)' $out/run_all.log | sort -u > $out/failing

    failed=0
    expect() {
      [ "$2" = "$3" ] || { echo "$1: $2, and this check expects $3" >&2; failed=1; }
    }
    expect "tests run" "$(get ran)" 1529
    expect "tests that failed" "$(get failures)" 8
    expect "tests that errored" "$(get errors)" 0
    expect "tests skipped" "$(get skipped)" 36
    expect "modules that could not be loaded" "$(grep -ac 'failed to load' $out/run_all.log)" 0
    expect "tests skipped for want of libchdb" "$(grep -ac 'libchdb.so/dylib not found' $out/run_all.log)" 0
    # the runner leaves a module that skips when it is imported out of its count: this is the one
    expect "modules that skip when imported, or cannot be" \
      "$(grep -E '^(skipped at import|cannot import)' $out/skipped-modules.log)" \
      "skipped at import: test_remote_query - Skipping remote query tests: REMOTE_HOST, REMOTE_USER, and REMOTE_PASSWORD must be set"
    # the tests that fail are those, and each fails on the engine's message about cgroups
    diff ${expectedFailing} $out/failing || failed=1
    expect "failures that carry the message about cgroups" \
      "$(grep -acE '^AssertionError: .*Cannot use cgroups reader' $out/run_all.log)" 8

    # Something must be able to fail: without the wheel the tests do not load
    status=0
    env PYTHONPATH= ${python}/bin/python -m unittest test_basic > $out/control-without-chdb.log 2>&1 || status=$?
    [ $status != 0 ] || { echo "the tests passed without chDB" >&2; failed=1; }
    grep -q "No module named 'chdb'" $out/control-without-chdb.log || { echo "no ModuleNotFoundError for chdb" >&2; failed=1; }

    [ $failed = 0 ] || exit 1
  ''
