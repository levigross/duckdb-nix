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

      # Crane vendors a git crate as `cargo package` would, keeping only the
      # files in the crate's `include` list and failing to copy the workspace
      # README that crates inherit. The crates need more than that: the build
      # script of vortex-duckdb reads cpp/include/table_function.h and
      # cbindgen.toml, and the crates include their README as documentation.
      # Upstream does not notice, since Corrosion builds from a full checkout.
      # Put back every file each vendored crate lacks, keeping the Cargo.toml
      # crane resolved.
      overrideVendorGitCheckout =
        packages: drv:
        if lib.any (p: p.name == "vortex-duckdb") packages then
          drv.overrideAttrs (old: {
            postInstall = (old.postInstall or "") + ''
              chmod -R u+w "$out"/*/

              # the crates' own directories, found by the name in their manifest
              find . -name Cargo.toml -not -path './target/*' | while read -r manifest; do
                name="$(sed -n 's/^name = "\(.*\)"$/\1/p' "$manifest" | head -1)"
                for vendored in "$out/$name"-[0-9]*; do
                  [ -d "$vendored" ] && cp -rn "$(dirname "$manifest")/." "$vendored/"
                done
              done

              # the README they inherit from the workspace root
              for vendored in "$out"/*/; do
                [ -e "$vendored/README.md" ] || cp README.md "$vendored/README.md"
              done

              crate="$out/vortex-duckdb-${(lib.findFirst (p: p.name == "vortex-duckdb") null packages).version}"

              # The build script regenerates include/vortex.h with cbindgen, which
              # runs `cargo metadata` on the crate. That needs the crate's sibling
              # path dependencies laid out as in the monorepo, and a flat vendor
              # directory is not. Use the vortex.h that is committed instead. It is
              # regenerated on every upstream build, so it may in principle lag the
              # Rust sources; the extension's smoke test exercises the boundary.
              substituteInPlace "$crate/build.rs" \
                --replace-fail "cbindgen_rust2c(&crate_dir);" "/* cbindgen_rust2c skipped, see vortex.nix */"
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
