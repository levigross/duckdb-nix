# The Rust half of the lance extension: the lance_duckdb_ffi static library.
# Upstream builds it by running cargo from CMake, which needs the network. Here
# it is an ordinary Rust build from the vendored Cargo.lock, and the extension's
# CMake is pointed at the result.
{
  lib,
  craneLib,
  protobuf,
  cmake,
  perl,
  pkg-config,
  openssl,
  src,
}:

let
  args = {
    pname = "lance-duckdb-ffi";
    version = "0.1.0";
    inherit src;

    # vendored next to this file, so evaluation needs no network
    cargoVendorDir = craneLib.vendorCargoDeps { cargoLock = ./rust/lance.Cargo.lock; };

    strictDeps = true;
    nativeBuildInputs = [
      protobuf
      # aws-lc-sys builds its C code with cmake
      cmake
      perl
      pkg-config
    ];
    buildInputs = [ openssl ];
    dontUseCmakeConfigure = true;

    # prost-build needs protoc
    env.PROTOC = lib.getExe protobuf;

    doCheck = false;
  };

  # the 680 dependencies, built once and reused
  cargoArtifacts = craneLib.buildDepsOnly args;
in
craneLib.buildPackage (
  args
  // {
    inherit cargoArtifacts;
    doInstallCargoArtifacts = false;

    # a static library, not a binary
    installPhaseCommand = ''
      install -Dm444 target/release/liblance_duckdb_ffi.a -t $out/lib
    '';

    meta = {
      description = "Rust static library of DuckDB's lance extension";
      homepage = "https://github.com/lance-format/lance-duckdb";
      license = lib.licenses.asl20;
    };
  }
)
