# The tests of the Python part of chDB, upstream's own at the tag: datastore/tests (a pandas-like
# DataStore on top of the engine) and the tests of the repository's tests/ that are about the
# installed module (chdb.durable, chdb.agents, importing chdb without pandas and pyarrow).
#
# What runs is the installed package, not the checkout: the wheel has the tests too, but not the
# data files they read (datastore/tests/dataset), so the tests are the tag's, and the package they
# import is the wheel's. The checkout's own pyproject.toml would put the checkout first on the
# path, so the tests are run from a directory of their own, laid out the way upstream runs them
# (`cd datastore && pytest tests/`), whose `datastore` is the installed one.
#
# Some of the tests are against a ClickHouse server. Upstream's fixture starts one with
# tests/setup_clickhouse_server.sh, which downloads the binary of ClickHouse when
# tests/.clickhouse/clickhouse is not there; the script and the fixture run as they are, with the
# ClickHouse of nixpkgs put there. test_writeback.py is run by a job of its own upstream, against
# two servers (.github/ci/clickhouse-pair.yml), which here are two of the same on the loopback.
{
  pkgs,
  chdb,
  pin,
}:

let
  src = pkgs.fetchFromGitHub {
    owner = "chdb-io";
    repo = "chdb";
    rev = pin.wrapper.tag;
    inherit (pin.tests.chdb) hash;
  };

  chdbPython = chdb.pythonModule pkgs.python3Packages;
  # what upstream's CI installs next to the wheel (pytest, hypothesis, ray; pandas comes with it)
  # and polars, which some tests import when it is there. duckdb and ibis, which two other tests
  # import when they are there, are not installed: with the `duckdb` of this repository's overlay
  # in place of nixpkgs', evaluating ibis-framework fails ("cannot coerce a function to a
  # string", from the pythonModule of pkgs/duckdb/default.nix).
  python = pkgs.python3.withPackages (ps: [
    chdbPython
    ps.pytest
    ps.hypothesis
    ps.ray
    ps.polars
  ]);
  # the same without chDB
  without = pkgs.python3.withPackages (ps: [
    ps.pytest
    ps.pandas
    ps.pyarrow
    ps.hypothesis
  ]);

  # the servers of the pair: the native port, the HTTP port and the one between servers
  pairConfig = pkgs.writeText "chdb-tests-pair-config.xml" ''
    <clickhouse>
      <tcp_port>@TCP@</tcp_port>
      <http_port>@HTTP@</http_port>
      <interserver_http_port>@INTER@</interserver_http_port>
      <listen_host>127.0.0.1</listen_host>
      <path>@DIR@/data/</path>
      <tmp_path>@DIR@/tmp/</tmp_path>
      <user_files_path>@DIR@/user_files/</user_files_path>
      <format_schema_path>@DIR@/format_schemas/</format_schema_path>
      <logger>
        <level>warning</level>
        <log>@DIR@/log/clickhouse-server.log</log>
        <errorlog>@DIR@/log/clickhouse-server.err.log</errorlog>
        <console>0</console>
      </logger>
      <user_directories>
        <users_xml><path>@DIR@/users.xml</path></users_xml>
        <local_directory><path>@DIR@/access/</path></local_directory>
      </user_directories>
      <max_server_memory_usage_to_ram_ratio>0.25</max_server_memory_usage_to_ram_ratio>
    </clickhouse>
  '';
  pairUsers = pkgs.writeText "chdb-tests-pair-users.xml" ''
    <clickhouse>
      <profiles>
        <default>
          <max_memory_usage>500000000</max_memory_usage>
        </default>
      </profiles>
      <users>
        <default>
          <password></password>
          <networks><ip>::/0</ip></networks>
          <profile>default</profile>
          <quota>default</quota>
          <access_management>1</access_management>
        </default>
      </users>
      <quotas>
        <default>
          <interval>
            <duration>3600</duration>
            <queries>0</queries>
            <errors>0</errors>
            <result_rows>0</result_rows>
            <read_rows>0</read_rows>
            <execution_time>0</execution_time>
          </interval>
        </default>
      </quotas>
    </clickhouse>
  '';
in
pkgs.runCommand "chdb-datastore-tests"
  {
    nativeBuildInputs = [ pkgs.clickhouse ];
  }
  ''
    export HOME=$TMPDIR
    export TZ=UTC
    # The sandbox has no store of certificate authorities (SSL_CERT_FILE names a file that is not
    # there), and the engine then fails to set up TLS at all: a test of the agent tool, which
    # sends a request over https to a socket that never answers, gets "Cannot load default CA
    # certificates" at once instead of the timeout that it tests for.
    export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    mkdir -p $out
    W=$TMPDIR/work
    site=${python}/${python.sitePackages}
    failed=0

    # the number before a word in the last line of pytest ("3 failed, 40 passed, 2 skipped in 5s")
    count() {
      grep -E ' in [0-9.]+s' $1 | tail -n 1 | grep -oE "[0-9]+ $2" | grep -oE '^[0-9]+' || echo 0
    }
    expect() {
      [ "$2" = "$3" ] || { echo "$1: $2, and this check expects $3" >&2; failed=1; }
    }

    pids=()
    trap 'kill "''${pids[@]}" 2>/dev/null || true; kill $(cat $W/overlay/datastore/tests/.clickhouse/clickhouse.pid 2>/dev/null) 2>/dev/null || true' EXIT

    # --- the layout: the installed datastore, with the tests of the tag in it, and the files of the
    # checkout that a test reads from above datastore/
    mkdir -p $W/overlay/datastore
    for f in $site/datastore/*; do
      [ "$(basename $f)" = tests ] || ln -s $f $W/overlay/datastore/
    done
    cp -r --no-preserve=mode ${src}/datastore/tests $W/overlay/datastore/tests
    cp ${src}/pyproject.toml $W/overlay/pyproject.toml
    printf '[pytest]\n' > $W/pytest.ini
    mkdir $W/overlay/datastore/tests/.clickhouse
    ln -s ${pkgs.clickhouse}/bin/clickhouse $W/overlay/datastore/tests/.clickhouse/clickhouse

    # run <log> <command>: the output goes to the log, the exit status next to it
    run() {
      local log=$1; shift
      local status=0
      "$@" 2>&1 | tee $out/$log || status=$?
      echo $status > $out/$log.status
      echo "$log: pytest exit status $status"
    }
    ds="env PYTHONPATH=$W/overlay:$W/overlay/datastore ${python}/bin/python -m pytest -c $W/pytest.ini --rootdir=$W -q -rsxX --tb=short -p no:cacheprovider"

    # --- datastore/tests, run from datastore/ as upstream does. The fixture starts the server.
    cd $W/overlay/datastore
    run datastore.log $ds tests/ --ignore=tests/test_writeback.py

    # --- the tests that upstream runs against two servers (test_writeback.py, in a job of its own).
    # The two tests of TestRemoteClickHousePushdown (test_pandas_col_compat.py), which ask for a
    # server by the same variables, are not run: given one, their setup_class fails in the engine's
    # parser, because it sends `CREATE OR REPLACE TABLE function remote(...) AS (...)`, which is
    # not SQL ("Syntax error: failed at position 34 (remote)"), under a comment that says to
    # tolerate the failure without catching it. Upstream never runs them against a server.
    start_server() {
      local d=$W/pair/$1
      mkdir -p $d/data $d/tmp $d/user_files $d/format_schemas $d/log
      sed -e "s|@DIR@|$d|g" -e "s|@TCP@|$2|" -e "s|@HTTP@|$3|" -e "s|@INTER@|$4|" ${pairConfig} > $d/config.xml
      cp ${pairUsers} $d/users.xml
      clickhouse server --config-file=$d/config.xml --pid-file=$d/pid > $d/out 2>&1 &
      pids+=($!)
      for i in $(seq 90); do
        clickhouse client --port $2 --query 'SELECT 1' > /dev/null 2>&1 && break
        sleep 1
      done
      clickhouse client --port $2 --multiquery < ${src}/.github/ci/$5
      clickhouse client --port $2 --query 'SELECT version()'
    }
    start_server ch1 9000 8123 9009 init-ch1.sql
    start_server ch2 9001 8124 9010 init-ch2.sql
    run writeback.log env \
      CHDB_TEST_HOST=127.0.0.1:9000 CHDB_TEST_USER=remote_user CHDB_TEST_PASSWORD=test123 CHDB_TEST_DATABASE=chdb_test \
      CHDB_TEST_TARGET_HOST=127.0.0.1:9001 CHDB_TEST_TARGET_USER=remote_user_2 CHDB_TEST_TARGET_PASSWORD=test456 CHDB_TEST_TARGET_DATABASE=chdb_test_2 \
      $ds tests/test_writeback.py

    # --- tests/ of the repository that are about the installed module. The durable ones are run
    # in a process of their own, as upstream does: the engine has one path of data at a time, and
    # a test that opens one cannot follow a test that has used the engine in memory.
    #
    # Left out of tests/: test_agents_smolagents.py, which skips itself without smolagents (that
    # needs gradio, and nixpkgs refuses to evaluate python3.14-gradio-6.29.0 "because it has
    # problems"); and tests/clickhouse_connect/, the tests of chDB as a backend of
    # clickhouse-connect, which upstream runs in a pipeline of its own
    # (.github/workflows/clickhouse-connect-backend.yml: the backend suite, a comparison with a
    # real server, and the suite of clickhouse-connect itself). They import clickhouse_connect,
    # which is not installed here, and were not looked into further.
    mkdir -p $W/root/tests
    for f in test_durable test_agents_chdbtool test_agents_conformance test_no_pandas_pyarrow; do
      cp ${src}/tests/$f.py $W/root/tests/
    done
    cd $W/root
    rs="${python}/bin/python -m pytest -c $W/pytest.ini --rootdir=$W/root -q -rsxX --tb=long -p no:cacheprovider"
    run durable.log $rs tests/test_durable.py
    run agents.log $rs tests/test_agents_chdbtool.py tests/test_agents_conformance.py tests/test_no_pandas_pyarrow.py

    for log in datastore writeback durable agents; do
      echo "$log: $(grep -E ' in [0-9.]+s' $out/$log.log | tail -n 1)"
    done

    # --- what the runs must come to, for this tag, this pandas and this engine. Nothing fails or
    # errors. Of the tests that skip, two are for modules that are not installed (duckdb, ibis),
    # two are the ones whose setup is broken (above), and the others are upstream's own: known
    # limitations and conditions on the version of pandas. Six tests are marked as expected to fail
    # and pass (not strictly: a strict one that passes fails); the list is in the log.
    for l in datastore writeback durable agents; do
      expect "$l: exit status of pytest" "$(cat $out/$l.log.status)" 0
      expect "$l: failed" "$(count $out/$l.log failed)" 0
      expect "$l: errors" "$(count $out/$l.log 'errors?')" 0
    done
    expect "datastore: passed" "$(count $out/datastore.log passed)" 11274
    expect "datastore: skipped" "$(count $out/datastore.log skipped)" 23
    expect "datastore: xfailed" "$(count $out/datastore.log xfailed)" 79
    expect "datastore: xpassed" "$(count $out/datastore.log xpassed)" 6
    skips="$(grep '^SKIPPED' $out/datastore.log)"
    expect "datastore: skipped for a module that is not installed" "$(echo "$skips" | grep -c 'could not import')" 2
    expect "datastore: skipped for want of a server" "$(echo "$skips" | grep -c 'set CHDB_TEST_HOST')" 2
    expect "datastore: skipped for want of the server of the fixture or its data" \
      "$(echo "$skips" | grep -cE 'binary not found|test_db|CHDB_TEST_TARGET|env vars not set')" 0
    expect "writeback: passed" "$(count $out/writeback.log passed)" 75
    expect "writeback: skipped" "$(count $out/writeback.log skipped)" 0
    expect "durable: passed" "$(count $out/durable.log passed)" 50
    expect "durable: skipped (the module skips itself when the engine lacks the ABI)" "$(count $out/durable.log skipped)" 0
    expect "agents: passed" "$(count $out/agents.log passed)" 52

    # --- Something must be able to fail. Without chDB the same tests do not even load; and with a
    # server that is not there, a test that needs one fails (upstream's fixture fails, it does not
    # skip) instead of passing.
    cd $W/root
    status=0
    ${without}/bin/python -m pytest -c $W/pytest.ini --rootdir=$W/root -q -p no:cacheprovider \
      tests/test_agents_conformance.py > $out/control-without-chdb.log 2>&1 || status=$?
    [ $status != 0 ] || { echo "the tests passed without chDB" >&2; failed=1; }
    grep -q "No module named 'chdb'" $out/control-without-chdb.log || { echo "no ModuleNotFoundError for chdb" >&2; failed=1; }
    cd $W/overlay/datastore
    status=0
    env TEST_CLICKHOUSE_HOST=127.0.0.1:1 PYTHONPATH=$W/overlay:$W/overlay/datastore \
      ${python}/bin/python -m pytest -c $W/pytest.ini --rootdir=$W -q -p no:cacheprovider \
      tests/test_remote_connection_integration.py > $out/control-no-server.log 2>&1 || status=$?
    [ $status != 0 ] || { echo "a test that needs a server passed without one" >&2; failed=1; }
    grep -q 'is not reachable' $out/control-no-server.log || { echo "no complaint about the server" >&2; failed=1; }

    [ $failed = 0 ] || exit 1
  ''
