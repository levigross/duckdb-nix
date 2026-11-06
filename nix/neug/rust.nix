# The Rust example of NeuG (examples/neug-rust-consumer), built on the crates of
# bindings/rust/neug, which link libneug_c.so (the package neug-c): the engine runs in the
# process of the program.
#
# The crates have no dependency outside this repository, so there is nothing to vendor and the
# lock files list the crates of the repository only. Nothing in them needs TLS, and `tls` is
# the choice the Rust programs of this repository have, made here so that the day one does, it
# is made the same way as for chDB (nix/chdb/rust.nix):
#   "none"     the lock file has no crate of TLS at all (what it is today)
#   "rustls"   the lock file has no openssl-sys or native-tls
#   "openssl"  OpenSSL and pkg-config are given to the build
# What "none" says is about the crates. libneug.so itself links OpenSSL (its httpfs and its
# service mode), so OpenSSL is in the closure of the program whichever is chosen.
{ pkgs }:

let
  inherit (pkgs) lib neug-c;

  example = ../../examples/neug-rust-consumer;
  lockFile = example + "/Cargo.lock";
  lock = builtins.readFile lockFile;

  # the example and the crates it uses are one source, with the example as the place to build
  source = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../bindings/rust/neug
      ../../examples/neug-rust-consumer
    ];
  };

  mentions = names: lib.any (name: lib.hasInfix "name = \"${name}\"" lock) names;

  program =
    {
      tls ? "none",
    }:
    assert lib.assertMsg (lib.elem tls [
      "none"
      "openssl"
      "rustls"
    ]) "tls is none, openssl or rustls";
    assert lib.assertMsg (
      tls != "none"
      || !(mentions [
        "openssl-sys"
        "native-tls"
        "rustls"
      ])
    ) "tls = none, and the lock file has a crate of TLS";
    assert lib.assertMsg (
      tls != "rustls"
      || !(mentions [
        "openssl-sys"
        "native-tls"
      ])
    ) "tls = rustls, and the lock file has openssl-sys or native-tls";
    pkgs.rustPlatform.buildRustPackage {
      pname = "neug-rust-consumer";
      version = "0.1.0";

      src = source;
      sourceRoot = "${source.name}/examples/neug-rust-consumer";
      cargoLock.lockFile = lockFile;

      strictDeps = true;
      nativeBuildInputs = lib.optional (tls == "openssl") pkgs.pkg-config;
      buildInputs = lib.optional (tls == "openssl") pkgs.openssl;

      # the crates link the library that Nix builds, and refuse a header of another version of
      # the interface
      env = {
        NEUG_LIB_DIR = "${neug-c}/lib";
        NEUG_INCLUDE_DIR = "${neug-c}/include";
        NEUG_DB_TMP_DIR = "/tmp";
        GLOG_minloglevel = "2";
      };

      # the tests of the example, and those of the crates of the bindings, which are another
      # workspace: the unit tests, and the examples in the documentation, built
      doCheck = true;
      postCheck = ''
        # (only the directory of the example is writable: the bindings build elsewhere)
        CARGO_TARGET_DIR="$TMPDIR/bindings-target" \
          cargo test --offline --release --manifest-path ../../bindings/rust/neug/Cargo.toml
      '';
    };
in
{
  inherit program;
}
