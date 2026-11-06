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
}
