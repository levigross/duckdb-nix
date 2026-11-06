# The C and C++ programs that chdb-core ships in examples/ as its tests of libchdb, run the way
# upstream runs them: each has a script (examples/run*.sh) that compiles it with clang against
# ../programs/local/chdb.h and ../libchdb.so and runs it. Here the sources are upstream's own at the
# tag (a sparse checkout of the directories the scripts and programs use), the library and the
# header are this repository's package, and clang is the compiler of the build under another
# name (a shim called clang), since the programs are plain C99 and C++20.
#
# The scripts want more than the program: runArrowQueryTest.sh and runArrowStreamParse.sh
# download nanoarrow when the directory is not there, which is where the pinned release is put;
# runDurableAbiTest.sh first checks the table of its test against the parsers of the engine
# (check_statement_coverage.py reads src/Parsers, which is in the checkout for that); the last one
# looks for liblz4 with pkg-config, to decode the compressed Arrow streams of the engine.
{
  pkgs,
  chdb,
  pin,
}:

let
  inherit (pkgs) lib;

  core = pkgs.fetchgit {
    url = "https://github.com/${pin.repo}";
    rev = pin.tag;
    sparseCheckout = pin.tests.core.sparseCheckout;
    inherit (pin.tests.core) hash;
  };

  nanoarrow = pkgs.fetchurl { inherit (pin.tests.nanoarrow) url hash; };

  # the scripts of examples/, which the check compares with the directory it is given, so that a
  # script that upstream adds is not left out unnoticed
  scripts = [
    "runArrowQueryTest"
    "runArrowStreamParse"
    "runArrowTest"
    "runAsanRegressionTest"
    "runConnSettingsTest"
    "runCppExamples"
    "runDurableAbiTest"
    "runInsertProgressTest"
    "runQueryParamsTest"
    "runShutdownTest"
    "runStackTraceTest"
    "runStreamErrorTest"
    "runStreamInsertTest"
    "runStreamQueryEofTest"
    "runStub"
    "runStubDlopen"
    "runStubSimple"
    "runVersionHeaderTest"
    "runVersionTest"
  ];

  # the scripts that do not pass with this library, and why; each must fail, and the others pass
  failing = {
    runCppExamples = "the examples and the C++ header disagree, and the header needs what the library does not export";
  };
in
pkgs.runCommandCC "chdb-core-c-tests"
  {
    nativeBuildInputs = [
      pkgs.pkg-config
      pkgs.python3
      pkgs.lz4.dev
      pkgs.glibc.bin
      pkgs.coreutils
    ];
  }
  ''
    export HOME=$TMPDIR
    mkdir -p $out
    W=$TMPDIR/chdb-core

    cp -r --no-preserve=mode ${core} $W

    # the header (and the C++ one) of the package are the ones of the source at the tag
    cmp ${chdb}/include/chdb.h $W/programs/local/chdb.h
    cmp ${chdb}/include/chdb.hpp $W/programs/local/chdb.hpp

    # the scripts look for the library in the directory above them
    ln -s ${chdb}/lib/libchdb.so $W/libchdb.so
    mkdir $W/examples/nanoarrow-${pin.tests.nanoarrow.version}
    tar -xzf ${nanoarrow} -C $W/examples/nanoarrow-${pin.tests.nanoarrow.version} --strip-components=1

    # clang, for the scripts, is the compiler of this build
    mkdir $TMPDIR/shim
    printf '#!/bin/sh\nexec cc "$@"\n' > $TMPDIR/shim/clang
    printf '#!/bin/sh\nexec c++ "$@"\n' > $TMPDIR/shim/clang++
    chmod +x $TMPDIR/shim/clang $TMPDIR/shim/clang++
    export PATH=$TMPDIR/shim:$PATH

    found="$(cd $W/examples && ls run*.sh | sed 's/\.sh$//' | sort | tr '\n' ' ')"
    known="${lib.concatStringsSep " " (lib.sort (a: b: a < b) scripts)} "
    [ "$found" = "$known" ] || {
      echo "examples/ has the scripts: $found" >&2
      echo "this check was written for: $known" >&2
      exit 1
    }

    passed=""; failed=""
    for s in ${lib.concatStringsSep " " scripts}; do
      args=""
      # the script only runs its programs when asked to; it builds them otherwise
      [ $s = runCppExamples ] && args="--run"
      echo "=== $s"
      if (cd $W/examples && timeout 900 bash ./$s.sh $args) > $out/$s.log 2>&1; then
        passed="$passed $s"
        echo "--- $s passed:"
      else
        failed="$failed $s"
        echo "--- $s failed:"
      fi
      tail -n 5 $out/$s.log | cut -c1-200
    done
    echo "passed:$passed"
    echo "failed:$failed"

    expected="${lib.concatStringsSep " " (lib.attrNames failing)}"
    [ "$(echo $failed)" = "$expected" ] || {
      echo "the scripts that failed are: $(echo $failed); this check expects: $expected" >&2
      exit 1
    }

    # A program can skip a test and still exit 0. The one skip there is: a leak test that needs
    # an AddressSanitizer build of the engine.
    [ "$(grep -il skip $out/run*.log)" = "$out/runAsanRegressionTest.log" ]
    [ "$(grep -ih skip $out/run*.log)" = "  skip (not an AddressSanitizer build)" ]

    # The four C++ examples fail for two reasons, and this shows both. They write chdb:: where the
    # header (the same tag, the same file as in the package) has namespace CHDB. With that put
    # right, the header wants CHDB::connect_chdb_with_exception from the library, which the
    # library does not export: it exports its C functions only.
    grep -q "chdb.* has not been declared" $out/runCppExamples.log
    if (cd $W/examples && c++ -std=c++20 -Dchdb=CHDB -I../programs/local -L.. chdbCppBasic.cpp -lchdb -o $TMPDIR/cpp-probe) > $out/cpp-probe.log 2>&1; then
      echo "the C++ example links once the namespace is aliased, so the exception above is out of date" >&2
      exit 1
    fi
    grep -q 'undefined reference to .CHDB::connect_chdb_with_exception' $out/cpp-probe.log
    if nm -D --defined-only ${chdb}/lib/libchdb.so | grep -q connect_chdb_with_exception; then
      echo "libchdb exports connect_chdb_with_exception, so the exception above is out of date" >&2
      exit 1
    fi

    # Something must be able to fail: with a header that says another version than the library, the
    # test of exactly that must fail, and say so
    substituteInPlace $W/programs/local/chdb.h --replace-fail '#define CHDB_VERSION "${chdb.version}"' '#define CHDB_VERSION "0.0.0"'
    if (cd $W/examples && bash ./runVersionHeaderTest.sh) > $out/control.log 2>&1; then
      echo "the test of the version passed with a header of another version" >&2
      exit 1
    fi
    grep -q 'header (0.0.0) and library (${chdb.version}) versions differ' $out/control.log
  ''
