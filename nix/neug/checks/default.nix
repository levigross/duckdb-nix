# What must work with the installed library: found through its CMake package, loading its
# extensions by name, answering a graph query. Each check has something that must fail.
{ pkgs }:

let
  inherit (pkgs) neug;
  extensions = pkgs.lib.escapeShellArgs neug.extensions;
in
{
  library = pkgs.stdenv.mkDerivation {
    name = "neug-library-check";
    src = ./consumer;
    nativeBuildInputs = [
      pkgs.cmake
      pkgs.ninja
    ];
    # the dependencies of the CMake package come with it (propagatedBuildInputs)
    buildInputs = [ neug ];

    doCheck = true;
    checkPhase = ''
      export HOME=$TMPDIR

      # the string_view of abseil is the one NeuG's headers are built against, as the build
      # applied it: a library that disagrees with its headers about it breaks at link time
      grep -q '^#define ABSL_OPTION_USE_STD_STRING_VIEW 0' ${neug}/include/absl/base/options.h

      ./consumer ${extensions} | tee output
      for name in ${extensions}; do
        grep -qi "loaded $name" output
      done
      grep -q 'friend of a friend of Alice: Carol' output

      # LOAD finds the extensions where the library was built to look, which is its own
      # prefix, and nowhere else: pointed at an empty directory it must fail
      mkdir empty
      if NEUG_EXTENSION_HOME_PYENV=$PWD/empty ./consumer parquet >/dev/null 2>&1; then
        echo "LOAD parquet worked with no extensions to load" >&2
        exit 1
      fi
    '';

    installPhase = "touch $out";
  };

  # The addon for Node.js, in the real node of nixpkgs: it loads, opens a database, loads the
  # extensions by name and answers. Without the package on the path of node it must not be
  # found, and a wrong query must throw (the script asserts that).
  nodejs = pkgs.runCommand "neug-nodejs-check" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
    export HOME=$TMPDIR
    cd $TMPDIR

    export NODE_PATH=${neug.nodejs}/lib/node_modules
    node ${./node-smoke.js} ${extensions}

    if NODE_PATH= node -e "require('neug')" >/dev/null 2>&1; then
      echo "require('neug') worked without the package on the path" >&2
      exit 1
    fi

    touch $out
  '';

  # The test suite of the addon for Node.js, upstream's own (npm test: tests/test-shim.js forks
  # each test_*.js). Two files open the "modern graph" at /tmp/modern_graph, which upstream's
  # workflow prepares with the helper of the shim first: the same here, in the scratch directory.
  # Nothing is left out. The same runner without the package on the path must fail.
  nodejs-tests = pkgs.runCommand "neug-nodejs-tests" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
    export HOME=$TMPDIR
    cd $TMPDIR

    cp -r ${neug.src}/tools/nodejs_bind/tests tests
    chmod -R u+w tests
    substituteInPlace tests/test_db_init.js tests/test_db_transaction.js \
      --replace-fail /tmp/modern_graph $TMPDIR/modern_graph

    export NODE_PATH=${neug.nodejs}/lib/node_modules
    export FLEX_DATA_DIR=${neug.src}/example_dataset/modern_graph
    node -e "
      const { Database } = require('neug');
      require('./tests/test-shim').prepareModernGraphDataset(Database, process.env.TMPDIR + '/modern_graph');
    "

    node tests/test-shim.js 2>&1 | tee suite.log
    grep -q "^# file failed: 0" suite.log
    grep -q "^# fail  0" suite.log

    if NODE_PATH= node tests/test-shim.js >/dev/null 2>&1; then
      echo "the suite passed without the package on the path, so it shows nothing" >&2
      exit 1
    fi

    touch $out
  '';
}
