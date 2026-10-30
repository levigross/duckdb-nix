# Several Rust static libraries cannot be linked into one binary: each carries
# its own copy of Rust's standard library, so the linker sees every std symbol
# defined once per library. Upstream avoids that by building each as its own
# loadable extension.
#
# Here the symbols that more than one library defines are renamed, with a prefix
# per library, in every member of that library. Definitions and references inside
# one library are renamed together, so they still match, and different libraries no
# longer collide. Each library keeps a private std, as it would as a loadable
# extension, and the symbols the extension itself calls (its FFI) are untouched.
#
# Merging the members into one object would also work, but forces every member
# in, including ones a normal link never pulls because they are dead code with
# unresolved references (aws-lc's HRSS key exchange wants an assembly routine
# that is not built). Renaming leaves the archives as they were.
{
  lib,
  runCommand,
  binutils,
}:

# { name = path to the .a; }
libraries:

runCommand "rust-staticlibs-isolated" { nativeBuildInputs = [ binutils ]; } ''
  mkdir -p $out/lib

  ${lib.concatStrings (
    lib.mapAttrsToList (name: archive: ''
      nm -g --defined-only ${archive} 2>/dev/null | awk 'NF == 3 { print $3 }' | sort -u > ${name}.syms
    '') libraries
  )}

  # what more than one library defines
  sort ${
    lib.concatMapStringsSep " " (name: "${name}.syms") (lib.attrNames libraries)
  } | uniq -d > duplicated.syms
  echo "$(wc -l < duplicated.syms) symbols are defined by more than one library"

  ${lib.concatStrings (
    lib.mapAttrsToList (name: archive: ''
      awk -v prefix=${name} '{ print $1, prefix "__" $1 }' duplicated.syms > ${name}.map
      objcopy --redefine-syms=${name}.map ${archive} $out/lib/${name}.a
    '') libraries
  )}

  # they must coexist now, which they did not before
  ld -r --whole-archive ${
    lib.concatMapStringsSep " " (name: "$out/lib/${name}.a") (lib.attrNames libraries)
  } -o /dev/null
''
