# The Rust half of the vortex extension: the vortex_duckdb static library.
# Upstream builds it with Corrosion, which CMake clones from git, and cargo,
# which fetches the vortex repository. Here it is an ordinary Rust build from
# the vendored Cargo.lock, and the extension's CMake is pointed at the result.
{
  lib,
  craneLib,
  runCommand,
  rustPlatform,
  cmake,
  perl,
  pkg-config,
  protobuf,
  openssl,
  src,
  duckdbSrc,
  duckdbVersion,
  gitHashes,
}:

let
  lockFile = ./rust/vortex.Cargo.lock;
  lock = builtins.fromTOML (builtins.readFile lockFile);

  # the vortex commit the lock resolves, for the version the extension reports
  vortexRev = lib.last (
    lib.splitString "#" (lib.findFirst (p: p.name == "vortex-duckdb") null lock.package).source
  );

  # Only the crate, with a lock that agrees with its manifest. The one upstream
  # commits pins an older vortex than Cargo.toml asks for; scripts/update.sh
  # re-resolves it, as upstream's online `cargo build` does on every build.
  crateSrc = runCommand "vortex-extension-crate" { } ''
    cp -R ${src}/vortex-extension $out
    chmod -R u+w $out
    cp ${lockFile} $out/Cargo.lock
  '';

  args = {
    pname = "vortex-duckdb-ffi";
    version = "0.1.0";
    src = crateSrc;

    # vendored next to this file, so evaluation needs no network
    cargoVendorDir = craneLib.vendorCargoDeps {
      cargoLock = lockFile;
      outputHashes = gitHashes;

      # Crane vendors a git crate as `cargo package` would, and vortex-duckdb's
      # `include` list leaves out cpp/include/table_function.h, which its own
      # build script needs. Upstream does not notice: Corrosion builds from a
      # full checkout. Put the crate's cpp directory back.
      overrideVendorGitCheckout =
        packages: drv:
        if lib.any (p: p.name == "vortex-duckdb") packages then
          drv.overrideAttrs (old: {
            postInstall = (old.postInstall or "") + ''
              crate="$out/vortex-duckdb-${(lib.findFirst (p: p.name == "vortex-duckdb") null packages).version}"
              chmod -R u+w "$crate"
              cp -rT vortex-duckdb/cpp "$crate/cpp"
            '';
          })
        else
          drv;
    };

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

    # Cargo builds a git dependency from where it is vendored, and vortex-duckdb's
    # build script writes its generated bindings (src/cpp.rs) into its own source
    # directory, which a store path does not allow. Upstream builds from a
    # writable checkout. Copy the vendor directory (following the links to the
    # git checkouts) and point cargo's source replacement at the copy.
    postConfigure = ''
      writable="$TMPDIR/vendor"
      cp -rL --no-preserve=mode "$cargoVendorDir" "$writable"
      sed -i "s|$cargoVendorDir|$writable|g" "$CARGO_HOME/config.toml"
    '';

    env = {
      PROTOC = lib.getExe protobuf;
      # what DuckDB's CMake passes to cargo through Corrosion
      DUCKDB_VERSION = duckdbVersion;
      DUCKDB_SOURCE_DIR = "${duckdbSrc}";
      VORTEX_VERSION = vortexRev;
    };

    doCheck = false;
  };

  # the 500 dependencies, built once and reused
  cargoArtifacts = craneLib.buildDepsOnly args;
in
craneLib.buildPackage (
  args
  // {
    inherit cargoArtifacts;
    doInstallCargoArtifacts = false;

    # a static library, not a binary
    installPhaseCommand = ''
      install -Dm444 target/release/libvortex_duckdb.a -t $out/lib
    '';

    meta = {
      description = "Rust static library of DuckDB's vortex extension";
      homepage = "https://github.com/vortex-data/duckdb-vortex";
      license = lib.licenses.asl20;
    };
  }
)
