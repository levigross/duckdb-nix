# What must work with the libraries: a program links them the way NeuG's vector_search
# extension does and uses an index for real. Linked as an ordinary library, which leaves out
# the components that register themselves, the same program must fail.
{ pkgs }:

let
  inherit (pkgs) zvec;
in
{
  library = pkgs.runCommandCC "zvec-library-check" { } ''
    export HOME=$TMPDIR
    cd $TMPDIR

    flags="-std=c++17 -O1 -DNDEBUG -I${zvec}/include ${./zvec_check.cc}"
    libs="${zvec}/lib/libzvec_core.a ${zvec}/lib/libzvec_turbo.a ${zvec}/lib/libzvec_ailego.a"
    system="${zvec}/lib/libroaring.a -pthread -ldl -lrt"

    # whole: the components register themselves in static initializers that nothing refers to
    c++ $flags -o check -Wl,--whole-archive $libs -Wl,--no-whole-archive $system
    ./check

    # as an ordinary library: the program builds and must not work
    c++ $flags -o plain $libs $system
    if ./plain >plain.out 2>&1; then
      echo "the program worked without --whole-archive, so this check shows nothing of it" >&2
      exit 1
    fi
    cat plain.out
    # and for that reason: the registry of the components that register themselves is empty
    grep -q HasMetric plain.out

    touch $out
  '';

  # The unit tests of zvec itself, upstream's own, for the libraries this package builds:
  # ailego (60 tests), core (34) and turbo (1). The same source, patches and flags as the
  # package, with the test targets built and run by ctest. The 59 tests of the database layer
  # (tests/db) are of code that is not part of this package: they link the library zvec, which
  # needs Arrow 21 (built from source with downloaded dependencies), RocksDB and protobuf. The
  # extension of NeuG does not use that layer either. Nothing else is left out.
  tests = zvec.overrideAttrs (old: {
    pname = "zvec-tests";
    doCheck = true;

    # the targets are the test programs, named like their files; the default build phase stays,
    # since the generator (Ninja) is only chosen for it
    ninjaFlags = [ ];

    # the googletest of zvec (1.10.0) uses uintptr_t without including <cstdint>, which GCC 15 and
    # later no longer let pass
    postPatch = old.postPatch + ''
      substituteInPlace thirdparty/googletest/googletest-1.10.0/googletest/src/gtest-death-test.cc \
        --replace-fail '# include <limits.h>' '# include <limits.h>
      # include <cstdint>'
    '';
    preBuild = ''
      ninjaFlagsArray+=( $(find ../tests/ailego ../tests/core ../tests/turbo -name '*_test.cc' -printf '%f\n' \
        | sed 's/\.cc$//' | sort -u) )
    '';

    checkPhase = ''
      runHook preCheck
      export LD_LIBRARY_PATH=$PWD/lib
      # every directory is run before the check fails, to see all that fails
      status=0
      for d in ailego core turbo; do
        echo "=== $d: $(ctest --test-dir tests/$d -N | grep -c 'Test *#') tests"
        ctest --test-dir tests/$d -j4 --timeout 1500 --output-on-failure --no-tests=error || status=1
      done
      [ $status = 0 ]
      runHook postCheck
    '';

    installPhase = "touch $out";
  });
}
