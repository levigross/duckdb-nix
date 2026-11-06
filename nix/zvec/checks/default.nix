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
}
