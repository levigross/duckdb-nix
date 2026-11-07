# The test suite of the Python module of NeuG (tools/python_bind/tests), upstream's own, run on
# the installed module in the sandbox: no network, and a home directory that holds only what is
# put there. What the tests need and cannot have is provided as described below, and what is left
# out is listed in `ignored` and `deselected`, each with its reason and the text of the error it
# gave in this sandbox (the sandbox cannot resolve a host name, and a program in it can write to
# its build directory and /tmp only).
{
  pkgs,
  neug,
  neugPython,
}:

let
  inherit (pkgs) lib;

  testPackages = ps: [
    ps.pytest
    ps.pytest-asyncio
    ps.pytest-timeout
    ps.pyarrow
    ps.pandas
    ps.requests
    ps.click
    # the Elle tester of the transactions (tests/transaction/elle_tester_insert.py)
    ps.networkx
  ];
  withModule = pkgs.python3.withPackages (ps: [ neugPython ] ++ testPackages ps);
  withoutModule = pkgs.python3.withPackages testPackages;

  # The archives of the datasets that the tests load (neug.datasets: modern_graph and
  # tinysnb), which the loader downloads from graphscope.oss-cn-beijing.aliyuncs.com into
  # ~/.neug/datasets when they are not there. That host did not answer when this was written
  # (the name does not resolve in the sandbox, and a request from outside timed out), so the
  # archives could not be pinned by hash: they are made here from the directories that the
  # sources carry for the same two datasets (example_dataset/<name>), as <name>.tar.gz with the
  # directory <name> in it, which is what the loader unpacks. They are NOT upstream's archives,
  # and what the originals hold is not known: nothing could be compared. What is known is that
  # the loader (neug/datasets/loader.py) imports 4 files of modern_graph and 8 of tinysnb by
  # name, that the directories hold them, and that every test that loads either dataset passes
  # (test_dataset.py, and the fixtures modern_graph and tinysnb of conftest.py). A file of the
  # originals that no test names would not be missed; one that differs in content from the
  # directory's would show only if a test depended on it, and none failed on that.
  datasets = pkgs.runCommand "neug-test-datasets" { nativeBuildInputs = [ pkgs.gnutar ]; } ''
    mkdir -p $out
    for name in modern_graph tinysnb; do
      tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
        -czf $out/$name.tar.gz -C ${neug.src}/example_dataset $name
    done
  '';

  # Files that are not run. Each is a defect of the sandbox or of the test's own needs, not of
  # the package.
  ignored = {
    "tests/test_extension_install_load.py" = ''
      6 tests, all `INSTALL <extension>`. Error: "Failed to execute query: INSTALL parquet.
      Error code: 1014, Error Message: ERR_IO_ERROR: Cannot delete existing extension file (no
      permission or error): .../lib/extension/parquet/libparquet.neug_extension ec=Permission
      denied". INSTALL (install_extension, src/execution/extension/extension.cc) fetches
      https://graphscope.oss-cn-beijing.aliyuncs.com/neug/extensions/v0.3.0/linux_x86_64/<name>/
      lib<name>.neug_extension.sha256 to compare the installed file with the repository's, and
      the log says "extension.cc:495 [Admin] Download failed, res.error()=Connection": with no
      network the file counts as different, and it is deleted to be downloaded again, which the
      read-only store forbids. The extensions are there already and LOAD finds them with no
      INSTALL (checks neug-library and neug-python).
    '';
    "tests/test_extension_functions.py" = ''
      6 tests, each starts with `INSTALL <extension>` (_load_extension, line 49): the same error
      and cause as test_extension_install_load.py.
    '';
    "tests/test_parquet_export_interop.py" = ''
      12 errors in a fixture, which runs a binary of the C++ tests of upstream: "AssertionError:
      Build parquet_carquet_export_test first: .../build/extension/parquet/
      parquet_carquet_export_test" (assert is_file()). The package builds no test binary
      (BUILD_TEST=OFF).
    '';
    "tests/test_lsqb.py" = ''
      TestLsqb::test_queries: "RuntimeError: LSQB_DATA_DIR environment variable is not set". The
      LSQB graph is bulk-loaded by upstream's workflow from a checkout of
      github.com/GraphScope/gstest (neug/lsqb-sf01) with a tool that the package does not build.
    '';
    "tests/test_java_driver.py" = ''
      test_java_driver_e2e starts a server and runs `mvn test` in tools/java_driver (upstream
      runs it only with enable-java-test): "FileNotFoundError: [Errno 2] No such file or
      directory: 'mvn'". Maven and the network it needs are not in the sandbox.
    '';
  };

  # Tests, of files that are run, that are not.
  deselected = {
    "tests/test_copy_temp.py::TestCopyTempRemoteHttpfs" = ''
      3 tests that read https://graphscope.oss-cn-beijing.aliyuncs.com/neug/vPerson.parquet:
      "Failed to probe HTTP file size for http://graphscope.oss-cn-beijing.aliyuncs.com/neug/
      vPerson.parquet: GET range probe failed ...: Could not resolve hostname" (no network).
    '';
    "tests/test_load.py::TestLoadFrom::test_load_vertices_and_edges_from_parquet_on_httpfs_oss" = ''
      Reads oss://graphscope/neug/vPerson.parquet from oss-cn-beijing.aliyuncs.com: "Failed to
      sniff Parquet schema: ... Input get_size callback failed" (no network).
    '';
    "tests/test_load.py::TestLoadFrom::test_load_vertices_and_edges_from_parquet_via_httpfs_http" = ''
      Reads http://graphscope.oss-cn-beijing.aliyuncs.com/neug/vPerson.parquet: "Could not
      resolve hostname" (no network).
    '';
    "tests/test_load.py::TestLoadFrom::test_load_vertices_and_edges_from_parquet_via_httpfs_https" = ''
      Reads https://graphscope.oss-cn-beijing.aliyuncs.com/neug/vPerson.parquet: "Could not
      resolve hostname" (no network).
    '';
    "tests/test_load.py::TestLoadFrom::test_load_from_parquet_on_public_httpfs_aws" = ''
      Reads a public bucket on S3, s3://ookla-open-data/parquet/performance/... in us-west-2:
      "Failed to sniff Parquet schema: ... Input get_size callback failed" (no network).
    '';
    "tests/test_dataset.py::test_load_ogbn_mag_small_dataset" = ''
      Downloads the dataset ogbn_mag_small, which is not in the sources: "RuntimeError: Failed to
      load dataset 'ogbn_mag_small': URL fetch failure on https://graphscope.oss-cn-beijing.
      aliyuncs.com/neug-dataset/ogbn_mag_small.tar.gz: [Errno -3] Temporary failure in name
      resolution" (no network; the loader is the one that the other datasets go through).
    '';
    "tests/test_call_params.py::test_call_echo_param" = ''
      Loads the extension test_out_of_tree: "Failed to execute query: LOAD test_out_of_tree. Error
      code: 1014, Error Message: ERR_IO_ERROR: Extension .../lib/extension/test_out_of_tree/
      libtest_out_of_tree.neug_extension not found in user install or wheel package". It is a
      fixture that upstream builds only for its tests (BUILD_EXTENSIONS=...;test_out_of_tree in
      .github/workflows/neug-extension-test.yml), through the build system of NeuG itself
      (build_extension_lib), and is not one of the six extensions.
    '';
    "tests/test_call_params.py::test_extension_catalog_function_available_after_reopen" = ''
      The same: LOAD test_out_of_tree, extension not found.
    '';
    "tests/test_extension_local_load.py::test_load_local_extension[test_out_of_tree]" = ''
      The same: "LOAD test_out_of_tree;" -> "Extension .../test_out_of_tree/
      libtest_out_of_tree.neug_extension not found". The other six parameters (the six
      extensions) are run.
    '';
  };

  report = title: attrs: ''
    echo ${lib.escapeShellArg title}
    ${lib.concatStrings (
      lib.mapAttrsToList (id: why: ''
        echo ${lib.escapeShellArg ("  " + id)}
        cat <<'EOF' | sed 's/^/      /'
        ${lib.removeSuffix "\n" why}
        EOF
      '') attrs
    )}
  '';

  ignoreArgs = lib.concatMapStringsSep " " (f: "--ignore=${f}") (lib.attrNames ignored);
  deselectArgs = lib.concatMapStringsSep " " (id: "--deselect=${lib.escapeShellArg id}") (
    lib.attrNames deselected
  );
in
pkgs.runCommand "neug-python-tests" { } ''
  export HOME=$TMPDIR
  cd $TMPDIR

  # What the tests find from where they are (Path(__file__).parents[3]): the layout of the
  # repository, with the tests copied to a place where conftest.py, which puts the directory
  # above them on sys.path, finds no neug but the installed one.
  mkdir -p src/tools/python_bind
  cp -r ${neug.src}/tools/python_bind/tests src/tools/python_bind/tests
  chmod -R u+w src
  ln -s ${neug.src}/example_dataset src/example_dataset
  ln -s ${neug.src}/extension src/extension
  cd src/tools/python_bind

  mkdir -p $HOME/.neug/datasets
  cp ${datasets}/*.tar.gz $HOME/.neug/datasets/

  export FLEX_DATA_DIR=${neug.src}/example_dataset/modern_graph
  export NEUG_RUN_EXTENSION_TESTS=true

  # A test that hangs is killed (the "thread" method, as a hang inside the library holds the
  # interpreter). The limit is six times the slowest test of the runs, 28 s to 46 s (the slowest
  # five are listed at the end of every run, on a machine that was also building); before the
  # service answered like brpc on a connection that is kept, one test took 211 s.
  flags="-p no:cacheprovider -q -rfEs --durations=5 --timeout=300 --timeout-method=thread"

  # The same runner without the module must fail, and because the module is not there
  if ${withoutModule}/bin/pytest $flags tests/test_call_string_literal.py >control.log 2>&1; then
    echo "the suite passed without the module, so it shows nothing" >&2
    exit 1
  fi
  grep -q "No module named 'neug'" control.log

  ${report "Left out, files:" ignored}
  ${report "Left out, tests:" deselected}

  ${withModule}/bin/pytest $flags tests tests/transaction/elle_tester_insert.py \
    ${ignoreArgs} ${deselectArgs}

  # nothing was downloaded: the home holds the two archives and what was unpacked from them
  test "$(ls $HOME/.neug/datasets | sort | tr '\n' ' ')" = "modern_graph modern_graph.tar.gz tinysnb tinysnb.tar.gz "

  touch $out
''
