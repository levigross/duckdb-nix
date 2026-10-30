# The Rust half of the delta extension: delta-kernel-rs's FFI library and its
# generated C/C++ headers. Upstream clones the repository and runs cargo from
# CMake (ExternalProject), which needs the network. Here it is an ordinary
# Rust build from the vendored Cargo.lock, and the extension's CMake is pointed
# at the result.
{
  lib,
  craneLib,
  cmake,
  perl,
  pkg-config,
  openssl,
  src,
}:

let
  args = {
    pname = "delta-kernel-ffi";
    version = "0.28.0";
    inherit src;

    # vendored next to this file, so evaluation needs no network
    cargoVendorDir = craneLib.vendorCargoDeps { cargoLock = ./rust/delta.Cargo.lock; };

    # the package and features the extension's CMake builds
    cargoExtraArgs = lib.concatStringsSep " " [
      "--locked"
      "--package delta_kernel_ffi"
      "--features default-engine-rustls,arrow,test-ffi,delta-kernel-unity-catalog,tracing"
    ];

    strictDeps = true;
    nativeBuildInputs = [
      # aws-lc-sys builds its C code with cmake
      cmake
      perl
      pkg-config
    ];
    buildInputs = [ openssl ];
    dontUseCmakeConfigure = true;

    doCheck = false;
  };

  # the 550 dependencies, built once and reused
  cargoArtifacts = craneLib.buildDepsOnly args;
in
craneLib.buildPackage (
  args
  // {
    inherit cargoArtifacts;
    doInstallCargoArtifacts = false;

    # a static library and the headers cbindgen generated for it
    installPhaseCommand = ''
      install -Dm444 target/release/libdelta_kernel_ffi.a -t $out/lib
      install -Dm444 target/ffi-headers/delta_kernel_ffi.h target/ffi-headers/delta_kernel_ffi.hpp \
        -t $out/ffi-headers
    '';

    meta = {
      description = "Rust FFI library of DuckDB's delta extension (delta-kernel-rs)";
      homepage = "https://github.com/delta-io/delta-kernel-rs";
      license = lib.licenses.asl20;
    };
  }
)
