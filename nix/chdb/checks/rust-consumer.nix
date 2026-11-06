# A Rust program, linked against our libchdb through the chdb-rust crate, runs queries. The
# same binary with its path to the library taken out must not start, so the check cannot pass
# without really using it.
{ pkgs, program }:

pkgs.runCommand "${program.pname}-check" { nativeBuildInputs = [ pkgs.patchelf ]; } ''
  export HOME=$TMPDIR
  cd $TMPDIR

  ${program}/bin/chdb-rust-consumer

  cp ${program}/bin/chdb-rust-consumer stripped
  chmod u+w stripped
  patchelf --remove-rpath stripped
  if ./stripped >/dev/null 2>&1; then
    echo "the program ran without a path to libchdb, so it does not use it" >&2
    exit 1
  fi

  touch $out
''
