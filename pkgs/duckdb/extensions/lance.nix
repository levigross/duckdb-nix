# The Rust half of the lance extension: the lance_duckdb_ffi static library.
# Upstream builds it by running cargo from CMake, which needs the network. Here
# it is an ordinary Rust build from the committed Cargo.lock, and the extension's
# CMake is pointed at the result.
{
  lib,
  rustPlatform,
  protobuf,
  cmake,
  perl,
  pkg-config,
  openssl,
  src,
  lockFile,
  # whether the lock file kept here differs from the one in the source, and has to replace it
  replaceLock ? false,
}:

rustPlatform.buildRustPackage (
  {
    pname = "lance-duckdb-ffi";
    version = "0.1.0";
    inherit src;

    cargoLock = { inherit lockFile; };

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

    meta = {
      description = "Rust static library of DuckDB's lance extension";
      homepage = "https://github.com/lance-format/lance-duckdb";
      license = lib.licenses.asl20;
    };
  }
  # The update script raises a crate that does not build with this toolchain, so the
  # lock differs from the source's. Not set when it does not, so that build stays as it was.
  // lib.optionalAttrs replaceLock {
    prePatch = ''
      cp ${lockFile} Cargo.lock
    '';
  }
)
