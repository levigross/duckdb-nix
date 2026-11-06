# What must work with the C interface of NeuG and the Rust crates made on it, each check with
# something that must fail, so that it cannot pass by accident.
{ pkgs }:

let
  inherit (pkgs) lib neug neug-c;
  extensions = lib.escapeShellArgs neug.extensions;
  shim = ../../../bindings/neug-c;
  rust = import ../rust.nix { inherit pkgs; };
in
{
  # A Rust program, with the engine in its own process through the crates: the graph, every
  # kind of cell, transactions, the six extensions and the paths that fail. The same binary with
  # its path to the library taken out must not start.
  rust-consumer =
    let
      program = rust.program { };
    in
    pkgs.runCommand "neug-rust-consumer-check" { nativeBuildInputs = [ pkgs.patchelf ]; } ''
      export HOME=$TMPDIR NEUG_DB_TMP_DIR=$TMPDIR GLOG_minloglevel=2
      cd $TMPDIR

      ${program}/bin/neug-rust-consumer ${extensions}

      cp ${program}/bin/neug-rust-consumer stripped
      chmod u+w stripped
      patchelf --remove-rpath stripped
      if ./stripped >/dev/null 2>&1; then
        echo "the program ran without a path to libneug_c.so" >&2
        exit 1
      fi

      touch $out
    '';

  # A C program that includes only neug_c.h (none of the C++ headers of NeuG) uses the whole
  # interface: a graph and a two-hop question, every type, a NULL, parameters, a transaction
  # that is rolled back, the six extensions, and the paths that fail.
  c-smoke =
    pkgs.runCommandCC "neug-c-smoke-check"
      {
        nativeBuildInputs = [
          pkgs.patchelf
          pkgs.binutils
        ];
      }
      ''
        export HOME=$TMPDIR NEUG_DB_TMP_DIR=$TMPDIR GLOG_minloglevel=2
        cd $TMPDIR

        cc -Wall -Wextra -Werror ${shim}/smoke.c -I${neug-c}/include -L${neug-c}/lib -lneug_c -o smoke
        ./smoke ${extensions}

        # the library exports its interface and nothing else, and needs no protobuf or abseil
        lib=${neug-c}/lib/libneug_c.so
        nm -D --defined-only $lib | awk '{print $3}' | sed 's/@.*//' | sort -u > defined
        stray="$(grep -vE '^(neug_|NEUG_C_)' defined || true)"
        if [ -n "$stray" ]; then
          echo "exported, and not of the interface: $stray" >&2
          exit 1
        fi
        foreign="$(nm -D --undefined-only -C $lib | grep -E 'protobuf|absl|glog|google::' || true)"
        if [ -n "$foreign" ]; then
          echo "needs from outside: $foreign" >&2
          exit 1
        fi
        echo "exports $(grep -c '^neug_' defined) functions and nothing else"

        # without its path to the library the program does not start
        cp smoke stripped
        patchelf --remove-rpath stripped
        if ./stripped >/dev/null 2>&1; then
          echo "the program ran without a path to libneug_c.so" >&2
          exit 1
        fi

        # a program built with a header of another version of the interface says so
        # (the program is copied next to the header: an include with quotes looks there first)
        mkdir other
        sed 's/#define NEUG_C_ABI_VERSION 1/#define NEUG_C_ABI_VERSION 2/' ${neug-c}/include/neug_c.h > other/neug_c.h
        grep -q 'NEUG_C_ABI_VERSION 2' other/neug_c.h
        cp ${shim}/smoke.c other/smoke.c
        cc -L${neug-c}/lib other/smoke.c -lneug_c -o other-abi
        if ./other-abi >/dev/null 2>&1; then
          echo "a program of another version of the interface ran" >&2
          exit 1
        fi

        touch $out
      '';
}
