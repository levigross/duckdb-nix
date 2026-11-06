# The Rust half of the vortex extension: the vortex_duckdb static library.
# Upstream builds it with Corrosion, which CMake clones from git, and cargo,
# which fetches the vortex repository. Here it is an ordinary Rust build from
# the Cargo.lock kept next to this file, and the extension's CMake is pointed at
# the result.
{
  lib,
  rustPlatform,
  cmake,
  perl,
  pkg-config,
  protobuf,
  openssl,
  src,
  lockFile,
  duckdbSrc,
  duckdbVersion,
  gitHashes,
}:

let
  # The lock upstream commits pins an older vortex than Cargo.toml asks for, so
  # scripts/update-duckdb.sh re-resolves it, as upstream's online `cargo build` does on
  # every build. It replaces the committed one before the build checks the two.
  lock = lib.importTOML lockFile;

  gitPackages = lib.filter (package: lib.hasPrefix "git+" (package.source or "")) lock.package;

  vortexDuckdb = lib.findFirst (package: package.name == "vortex-duckdb") null lock.package;

  # the vortex commit the lock resolves, for the version the extension reports
  vortexRev = lib.last (lib.splitString "#" vortexDuckdb.source);
in
rustPlatform.buildRustPackage {
  pname = "vortex-duckdb-ffi";
  version = "0.1.0";
  inherit src;
  sourceRoot = "${src.name}/vortex-extension";

  prePatch = ''
    cp ${lockFile} Cargo.lock
  '';
  cargoLock = {
    inherit lockFile;
    # one hash for each git commit, which every crate from it shares
    outputHashes = lib.listToAttrs (
      map (
        package: lib.nameValuePair "${package.name}-${package.version}" gitHashes.${package.source}
      ) gitPackages
    );
  };

  # The build script of vortex-duckdb regenerates include/vortex.h with cbindgen,
  # which runs `cargo metadata` on the crate. That needs the crates it depends on
  # laid out as in the monorepo, and a vendor directory is flat. Use the vortex.h
  # that is committed instead. Upstream regenerates it on every build, so it may in
  # principle lag the Rust sources; the extension's smoke test exercises the boundary.
  #
  # Several crates also take the README of the workspace as their documentation,
  # and a vendored crate has only its own directory. It would only feed rustdoc,
  # so an empty one will do.
  postPatch = ''
    substituteInPlace "$cargoDepsCopy/vortex-duckdb-${vortexDuckdb.version}/build.rs" \
      --replace-fail "cbindgen_rust2c(&crate_dir);" "/* cbindgen_rust2c skipped, see vortex.nix */"
    ${lib.concatMapStrings (package: ''
      [ -e "$cargoDepsCopy/${package.name}-${package.version}/README.md" ] ||
        touch "$cargoDepsCopy/${package.name}-${package.version}/README.md"
    '') gitPackages}
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
    DUCKDB_SOURCE_DIR = "${duckdbSrc}";
    VORTEX_VERSION = vortexRev;
  };

  doCheck = false;

  meta = {
    description = "Rust static library of DuckDB's vortex extension";
    homepage = "https://github.com/vortex-data/duckdb-vortex";
    license = lib.licenses.asl20;
  };
}
