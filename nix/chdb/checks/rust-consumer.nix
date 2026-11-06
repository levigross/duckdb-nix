# A Rust program, linked against our libchdb through the chdb-rust crate, runs queries. The
# crate's build script is given the library and the header, so it downloads nothing. The same
# binary with its path to the library taken out must not start, so the check cannot pass
# without really using it.
{ pkgs, chdb }:

let
  example = ../../../examples/chdb-rust-consumer;

  program = pkgs.rustPlatform.buildRustPackage {
    pname = "chdb-rust-consumer";
    version = "0.1.0";
    src = example;
    cargoLock.lockFile = example + "/Cargo.lock";

    strictDeps = true;
    nativeBuildInputs = [
      # the crate generates its bindings from chdb.h
      pkgs.rustPlatform.bindgenHook
      pkgs.pkg-config
    ];
    # its build script can download libchdb, with reqwest, which is not told to here
    buildInputs = [ pkgs.openssl ];

    env = {
      CHDB_LIB_DIR = "${chdb}/lib";
      CHDB_INCLUDE_DIR = "${chdb}/include";
    };

    doCheck = false;
  };
in
pkgs.runCommand "chdb-rust-consumer-check" { nativeBuildInputs = [ pkgs.patchelf ]; } ''
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
