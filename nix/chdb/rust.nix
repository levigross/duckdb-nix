# The Rust example of chDB (examples/chdb-rust-consumer), built against our libchdb with a
# choice of TLS stack, since people need one or the other.
#
# The crate chdb-rust has a build script that can download an engine, and it does that with
# reqwest, whose default TLS is OpenSSL. That is not used here (CHDB_LIB_DIR names ours),
# but it is compiled, so by default OpenSSL is needed to build. With `tls = "rustls"` the
# crate is patched to give reqwest rustls instead, and nothing in the build or the program
# needs OpenSSL: the lock file of that build is Cargo.rustls.lock. Both lock files are made
# by scripts/update-chdb-rust.sh.
#
# The crate has a feature of its own that uses TLS when the program runs: `durable-s3`, with
# ureq and rustls, to keep a durable object in S3 or a store that speaks its protocol.
{ pkgs, chdb }:

let
  inherit (pkgs) lib;

  example = ../../examples/chdb-rust-consumer;

  lockOf = tls: if tls == "rustls" then example + "/Cargo.rustls.lock" else example + "/Cargo.lock";

  # The crate chdb-rust as the OpenSSL lock file has it, checksum verified, with the TLS of
  # its build script's reqwest changed to rustls.
  crateForRustls =
    let
      locked = lib.findFirst (
        package: package.name == "chdb-rust"
      ) (throw "chdb-rust is not locked") (lib.importTOML (lockOf "openssl")).package;
      vendor = pkgs.rustPlatform.importCargoLock { lockFile = lockOf "openssl"; };
    in
    pkgs.runCommand "chdb-rust-${locked.version}-rustls" { } ''
      cp -rL --no-preserve=mode ${vendor}/chdb-rust-${locked.version} $out
      chmod -R u+w $out
      rm -f $out/.cargo-checksum.json
      substituteInPlace $out/Cargo.toml --replace-fail \
        $'[build-dependencies.reqwest]\nversion = "0.11"\nfeatures = ["blocking"]' \
        $'[build-dependencies.reqwest]\nversion = "0.11"\nfeatures = ["blocking", "rustls-tls"]\ndefault-features = false'
    '';

  # the example, for the rustls build with the patched crate in place of the one of crates.io
  sourceOf =
    tls:
    if tls == "rustls" then
      pkgs.runCommand "chdb-rust-consumer-rustls-source" { } ''
        cp -r ${example} $out
        chmod -R u+w $out
        mv $out/Cargo.rustls.lock $out/Cargo.lock
        cat >> $out/Cargo.toml <<EOF

        [patch.crates-io]
        chdb-rust = { path = "${crateForRustls}" }
        EOF
      ''
    else
      example;

  program =
    {
      tls ? "openssl",
      durableS3 ? false,
    }:
    assert lib.elem tls [
      "openssl"
      "rustls"
    ];
    # the build with rustls has no OpenSSL anywhere: not in its lock file, and the build is
    # given neither openssl nor pkg-config, so it could not have used it
    assert lib.assertMsg (
      tls != "rustls" || !(lib.hasInfix "openssl-sys" (builtins.readFile (lockOf "rustls")))
    ) "Cargo.rustls.lock has openssl-sys: run scripts/update-chdb-rust.sh";
    pkgs.rustPlatform.buildRustPackage {
      pname = "chdb-rust-consumer-${tls}${lib.optionalString durableS3 "-s3"}";
      version = "0.1.0";
      src = sourceOf tls;
      cargoLock.lockFile = lockOf tls;
      buildFeatures = lib.optional durableS3 "durable-s3";

      strictDeps = true;
      nativeBuildInputs = [
        # the crate generates its bindings from chdb.h
        pkgs.rustPlatform.bindgenHook
      ]
      ++ lib.optional (tls == "openssl") pkgs.pkg-config;
      buildInputs = lib.optional (tls == "openssl") pkgs.openssl;

      env = {
        CHDB_LIB_DIR = "${chdb}/lib";
        CHDB_INCLUDE_DIR = "${chdb}/include";
      };

      doCheck = false;
    };
in
{
  inherit crateForRustls program;
}
