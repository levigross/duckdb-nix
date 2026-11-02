# The Rust half of the delta extension: delta-kernel-rs's FFI library and its
# generated C/C++ headers. Upstream clones the repository and runs cargo from
# CMake (ExternalProject), which needs the network. Here it is an ordinary
# Rust build from the committed Cargo.lock, and the extension's CMake is pointed
# at the result.
{
  lib,
  rustPlatform,
  cmake,
  perl,
  pkg-config,
  openssl,
  src,
  lockFile,
  # the delta-kernel-rs release, and the features the extension builds it with
  version,
  features,
}:

rustPlatform.buildRustPackage (
  {
    pname = "delta-kernel-ffi";
    inherit version;
    inherit src;

    cargoLock = { inherit lockFile; };

    # the package the extension's CMake builds
    cargoBuildFlags = [
      "--package"
      "delta_kernel_ffi"
    ];
    buildFeatures = features;

    strictDeps = true;
    nativeBuildInputs = [
      # aws-lc-sys builds its C code with cmake
      cmake
      perl
      pkg-config
    ];
    buildInputs = [ openssl ];
    dontUseCmakeConfigure = true;

    # the headers that cbindgen generates for the library
    postInstall = ''
      install -Dm444 target/ffi-headers/delta_kernel_ffi.h target/ffi-headers/delta_kernel_ffi.hpp \
        -t $out/ffi-headers
    '';

    doCheck = false;

    meta = {
      description = "Rust FFI library of DuckDB's delta extension (delta-kernel-rs)";
      homepage = "https://github.com/delta-io/delta-kernel-rs";
      license = lib.licenses.asl20;
    };
  }
  # The kernel commits no Cargo.lock before 0.21 (it ignores it), so the build gets
  # the one this repository keeps. From then on the source has it, and the build
  # must stay as it was.
  // lib.optionalAttrs (lib.versionOlder version "0.21.0") {
    prePatch = ''
      cp ${lockFile} Cargo.lock
    '';
  }
)
