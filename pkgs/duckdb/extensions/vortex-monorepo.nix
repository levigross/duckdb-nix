# The Rust half of the vortex extension before DuckDB 2.0: the vortex_duckdb
# static library. There the crate is part of the vortex repository, which
# duckdb-vortex has as a submodule, and its build script downloads DuckDB's
# sources (and, for a dynamic library nothing here links, a release of DuckDB).
# Upstream's CMake builds it with Corrosion, which it clones from git. Here it is
# an ordinary Rust build of that repository's own Cargo.lock, with the DuckDB
# sources the build script wants put where it looks, and the extension's CMake is
# pointed at the result. From 2.0 the crate is standalone: see vortex.nix.
{
  lib,
  rustPlatform,
  cmake,
  perl,
  pkg-config,
  protobuf,
  openssl,
  # the vortex repository
  src,
  lockFile,
  duckdbSrc,
  duckdbVersion,
}:

let
  version = lib.removePrefix "v" duckdbVersion;
  before15 = lib.versionOlder version "1.5";
in
rustPlatform.buildRustPackage {
  pname = "vortex-duckdb-ffi";
  version = "0.1.0";
  inherit src;

  cargoLock.lockFile = lockFile;
  cargoBuildFlags = [
    "--package"
    "vortex-duckdb"
  ];

  # Only the static library is wanted, and the dynamic one would have to link a
  # libduckdb the build script downloads.
  postPatch = ''
    substituteInPlace vortex-duckdb/Cargo.toml \
      --replace-fail 'crate-type = ["staticlib", "cdylib", "rlib"]' 'crate-type = ["staticlib"]'
  ''
  + lib.optionalString before15 ''
    # no DuckDB library to download: nothing links one
    substituteInPlace vortex-duckdb/build.rs \
      --replace-fail 'let zip_lib_path = download_duckdb_lib_archive().unwrap();' "" \
      --replace-fail 'extract_duckdb_libraries(zip_lib_path).unwrap()' 'PathBuf::from(env::var("OUT_DIR").unwrap())'
  ''
  + lib.optionalString (lib.versionAtLeast version "1.5.2") ''
    # The C API of DuckDB 1.5.2 has a GEOMETRY type, which the vortex revision that
    # DuckDB 1.5 pins was written before; its match must cover every type
    substituteInPlace vortex-duckdb/src/convert/dtype.rs \
      --replace-fail 'DUCKDB_TYPE::DUCKDB_TYPE_INTEGER_LITERAL => todo!(),' \
      'DUCKDB_TYPE::DUCKDB_TYPE_INTEGER_LITERAL => todo!(),
            DUCKDB_TYPE::DUCKDB_TYPE_GEOMETRY => vortex_bail!("geometry is not supported"),'
  '';

  # The build script keeps what it would download under target/, and skips a
  # download whose file is there: DuckDB's sources, and from 1.5 a library of DuckDB.
  preBuild =
    if before15 then
      ''
        mkdir -p target/duckdb-source-v${version}
        ln -s ${duckdbSrc} target/duckdb-source-v${version}/duckdb-${version}
        touch target/duckdb-source-v${version}/duckdb-source-v${version}.zip
      ''
    else
      ''
        mkdir -p target/duckdb-source-v${version} target/duckdb-lib-v${version}
        ln -s ${duckdbSrc} target/duckdb-source-v${version}/duckdb-${version}
        # the path with its last extension replaced, as the build script writes it
        touch target/duckdb-source-v${lib.versions.majorMinor version}.zip
        touch target/duckdb-lib-v${version}/libduckdb-linux-amd64.zip target/duckdb-lib-v${version}/libduckdb.so
      '';

  # The extension's C++ includes the header that cbindgen generates from this crate.
  postInstall = ''
    install -Dm644 vortex-duckdb/include/vortex.h $out/include/vortex.h
  '';

  strictDeps = true;
  nativeBuildInputs = [
    # libclang for the bindgen of DuckDB's headers
    rustPlatform.bindgenHook
    # aws-lc-sys builds its C code with cmake
    cmake
    perl
    pkg-config
    protobuf
  ];
  buildInputs = [ openssl ];
  dontUseCmakeConfigure = true;

  env = {
    PROTOC = lib.getExe protobuf;
    # what DuckDB's CMake passes to cargo through Corrosion
    DUCKDB_VERSION = duckdbVersion;
  };

  doCheck = false;

  meta = {
    description = "Rust static library of DuckDB's vortex extension, before DuckDB 2.0";
    homepage = "https://github.com/vortex-data/duckdb-vortex";
    license = lib.licenses.asl20;
  };
}
